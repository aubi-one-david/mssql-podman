#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
CONTAINER_NAME="${MSSQL_CONTAINER_NAME:-mssql-server}"
IMAGE="mcr.microsoft.com/mssql/server:2025-latest"
SA_PASSWORD="${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD environment variable}"
HOST_PORT=1433
CONTAINER_PORT=1433
MSSQL_PID="Developer"
MEMORY_LIMIT="6g"
SQL_MAX_MEMORY_MB=5120   # Leave ~1 GB for OS/non-buffer overhead inside container

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/volumes/data"

# ── Helpers ──────────────────────────────────────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }

is_running() {
    podman ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

exists() {
    podman ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd_start() {
    if is_running; then
        yellow "Container '${CONTAINER_NAME}' is already running."
        cmd_status
        return 0
    fi

    # If a stopped container exists, remove it so we can recreate cleanly
    if exists; then
        yellow "Removing stopped container '${CONTAINER_NAME}'..."
        podman rm "${CONTAINER_NAME}" >/dev/null
    fi

    mkdir -p "${DATA_DIR}"

    echo "Starting ${CONTAINER_NAME}..."
    podman run -d \
        --name "${CONTAINER_NAME}" \
        --user root \
        --memory "${MEMORY_LIMIT}" \
        -e ACCEPT_EULA=Y \
        -e "MSSQL_SA_PASSWORD=${SA_PASSWORD}" \
        -e "MSSQL_PID=${MSSQL_PID}" \
        -e MSSQL_AGENT_ENABLED=true \
        -p "${HOST_PORT}:${CONTAINER_PORT}" \
        -v "${DATA_DIR}:/var/opt/mssql:Z" \
        "${IMAGE}" >/dev/null

    echo "Waiting for SQL Server to become ready..."
    local retries=30
    while (( retries > 0 )); do
        if podman exec "${CONTAINER_NAME}" \
            /opt/mssql-tools18/bin/sqlcmd \
            -S localhost -U sa -P "${SA_PASSWORD}" \
            -C -Q "SELECT 1" &>/dev/null; then

            # Wait for any background upgrades (msdb, model, etc.) to settle
            echo "Waiting for post-startup tasks to complete..."
            sleep 10

            # Cap SQL Server's internal memory usage
            podman exec "${CONTAINER_NAME}" \
                /opt/mssql-tools18/bin/sqlcmd \
                -S localhost -U sa -P "${SA_PASSWORD}" \
                -C -b -Q "
                    EXEC sp_configure 'show advanced options', 1;
                    RECONFIGURE;
                    EXEC sp_configure 'max server memory', ${SQL_MAX_MEMORY_MB};
                    RECONFIGURE;
                " || yellow "Warning: could not set max server memory"

            green "SQL Server is ready (memory capped at ${MEMORY_LIMIT}, SQL max ${SQL_MAX_MEMORY_MB} MB)."
            cmd_status
            return 0
        fi
        retries=$((retries - 1))
        sleep 2
    done

    red "SQL Server did not become ready in time. Check logs:"
    echo "  $0 logs"
    return 1
}

cmd_stop() {
    if ! is_running; then
        yellow "Container '${CONTAINER_NAME}' is not running."
        return 0
    fi

    echo "Stopping ${CONTAINER_NAME}..."

    # Ask SQL Server to shut down gracefully (checkpoints all DBs)
    echo "  Issuing SHUTDOWN to SQL Server..."
    podman exec "${CONTAINER_NAME}" \
        /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "${SA_PASSWORD}" \
        -C -Q "SHUTDOWN;" &>/dev/null || true

    # Wait for the container to exit on its own, with a safety timeout
    podman stop -t 120 "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    podman rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    green "Stopped and removed container."
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_status() {
    if ! is_running; then
        yellow "Container '${CONTAINER_NAME}' is not running."
        return 0
    fi

    echo "── Container ──────────────────────────────────────────"
    podman ps --filter "name=${CONTAINER_NAME}" --format \
        "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    echo ""

    echo "── Resource Usage ────────────────────────────────────"
    podman stats --no-stream --format \
        "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.BlockIO}}\t{{.PIDs}}" \
        "${CONTAINER_NAME}"
    echo ""

    echo "── Volume ─────────────────────────────────────────────"
    podman unshare du -sh "${DATA_DIR}" 2>/dev/null || echo "  (no data yet)"
}

cmd_logs() {
    local lines="${1:-50}"
    podman logs --tail "${lines}" "${CONTAINER_NAME}"
}

cmd_errorlog() {
    if ! is_running; then
        red "Container '${CONTAINER_NAME}' is not running."
        return 1
    fi

    local errors_only="${1:-}"
    local log="/var/opt/mssql/log/errorlog"

    if [[ "${errors_only}" == "--errors" ]]; then
        echo "── SQL Server Errors ──────────────────────────────────"
        podman exec "${CONTAINER_NAME}" cat "${log}" \
            | grep -iE "error|fail|denied|abort" \
            | while IFS= read -r line; do red "${line}"; done
    else
        echo "── SQL Server Error Log ───────────────────────────────"
        podman exec "${CONTAINER_NAME}" cat "${log}" \
            | while IFS= read -r line; do
                if echo "${line}" | grep -qiE "error|fail|denied|abort"; then
                    red "${line}"
                else
                    echo "${line}"
                fi
            done
    fi
}

cmd_sqlcmd() {
    if ! is_running; then
        red "Container '${CONTAINER_NAME}' is not running."
        return 1
    fi
    podman exec -it "${CONTAINER_NAME}" \
        /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "${SA_PASSWORD}" -C
}

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $0 {start|stop|restart|status|logs [N]|--logs [--errors]|sqlcmd}

Commands:
  start              Start the MSSQL container (waits for readiness)
  stop               Gracefully stop and remove the container
  restart            Stop then start
  status             Show container state and resource usage
  logs [N]           Show last N container log lines (default: 50)
  --logs             Show SQL Server error log (with error highlighting)
  --logs --errors    Show only error/failure lines from the log
  sqlcmd             Open an interactive sqlcmd session
EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    logs)    cmd_logs "${2:-50}" ;;
    --logs)  cmd_errorlog "${2:-}" ;;
    sqlcmd)  cmd_sqlcmd  ;;
    *)       usage; exit 1 ;;
esac

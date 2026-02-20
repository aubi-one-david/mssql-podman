# mssql-podman

Manage a containerised Microsoft SQL Server instance via Podman, with an optional PyQt5 system-tray monitor.

## What's included

| File | Purpose |
|---|---|
| `mssql.sh` | Start / stop / restart the MSSQL container, open `sqlcmd`, view logs |
| `mssql_tray.py` | System-tray icon that polls container status and exposes start/stop/restart |
| `test-mssql.sh` | Integration test suite (creates a DB, inserts rows, verifies persistence) |
| `test_mssql_tray.py` | Unit tests for the tray app (mocked, no container needed) |

## Prerequisites

- **Podman** (rootless)
- **Microsoft SQL Server 2025 container image** — pulled automatically on first start:
  `mcr.microsoft.com/mssql/server:2025-latest`
- **Python 3.10+** and **PyQt5** (for the tray app only)

## Quick start

```bash
# Set the SA password (required)
export MSSQL_SA_PASSWORD='YourStrongPassword123!'

# Start the MSSQL container
./mssql.sh start

# Check status and resource usage
./mssql.sh status

# Open an interactive sqlcmd session
./mssql.sh sqlcmd

# Stop gracefully
./mssql.sh stop
```

### All `mssql.sh` commands

| Command | Description |
|---|---|
| `start` | Create and start the container; wait for SQL Server readiness |
| `stop` | Graceful `SHUTDOWN` then remove the container |
| `restart` | Stop + start |
| `status` | Container state, resource usage, volume size |
| `logs [N]` | Last *N* container log lines (default 50) |
| `--logs` | SQL Server error log with error highlighting |
| `--logs --errors` | Error/failure lines only |
| `sqlcmd` | Interactive `sqlcmd` session as `sa` |

### System tray

```bash
python3 mssql_tray.py
```

A coloured circle appears in the system tray:
- **Green** — container running
- **Red** — container stopped
- **Yellow** — status unknown

Right-click for Start / Stop / Restart / Quit.

## Data persistence

SQL Server data is stored in `volumes/data/` (git-ignored). The volume survives container stop/start cycles.

## Running tests

```bash
# Integration tests (starts/stops the real container)
./test-mssql.sh

# Tray app unit tests (no container needed)
python3 -m pytest test_mssql_tray.py -v
# or
python3 -m unittest test_mssql_tray.py -v
```

## Configuration

All configuration is via environment variables with sensible defaults:

| Environment variable | Default | Purpose |
|---|---|---|
| `MSSQL_SA_PASSWORD` | *(required)* | SA account password |
| `MSSQL_CONTAINER_NAME` | `mssql-server` | Podman container name |

Additional settings can be changed at the top of `mssql.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `HOST_PORT` | `1433` | Port exposed on the host |
| `MEMORY_LIMIT` | `6g` | Container memory cap |
| `SQL_MAX_MEMORY_MB` | `5120` | SQL Server max memory (sp_configure) |

## License

MIT

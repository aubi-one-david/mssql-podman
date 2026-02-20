#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSSQL_SH="${SCRIPT_DIR}/mssql.sh"

CONTAINER_NAME="${MSSQL_CONTAINER_NAME:-mssql-server}"
SA_PASSWORD="${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD environment variable}"

PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────────
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }

run_sql() {
    podman exec "${CONTAINER_NAME}" \
        /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "${SA_PASSWORD}" \
        -C -b -h -1 -W \
        -Q "$1" 2>/dev/null
}

assert_contains() {
    local label="$1" output="$2" expected="$3"
    if echo "${output}" | grep -qF "${expected}"; then
        green "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        red "  FAIL: ${label}"
        red "    expected to contain: ${expected}"
        red "    got: ${output}"
        FAIL=$((FAIL + 1))
    fi
}

# ── Clean slate ──────────────────────────────────────────────────────────────
echo "============================================"
echo " MSSQL Podman Test Suite"
echo "============================================"
echo ""

echo "── Ensuring clean state ──"
"${MSSQL_SH}" stop 2>/dev/null || true
echo ""

# ── Test 1: Start ─────────────────────────────────────────────────────────────
echo "── Test 1: Start container ──"
"${MSSQL_SH}" start
echo ""

# ── Test 2: Basic connectivity ────────────────────────────────────────────────
echo "── Test 2: Basic connectivity ──"
result=$(run_sql "SELECT @@VERSION")
assert_contains "SELECT @@VERSION returns output" "${result}" "Microsoft SQL Server"

result=$(run_sql "SELECT SERVERPROPERTY('Edition')")
assert_contains "Developer edition" "${result}" "Developer"
echo ""

# ── Test 3: SQL Server Agent is running ────────────────────────────────────────
echo "── Test 3: SQL Server Agent is running ──"
result=$(run_sql "SELECT status_desc FROM sys.dm_server_services WHERE servicename LIKE '%Agent%'")
assert_contains "SQL Server Agent is running" "${result}" "Running"
echo ""

# ── Test 4: Create database and table, insert data ────────────────────────────
echo "── Test 4: Create database, table, insert data ──"

run_sql "
IF DB_ID('TestDB') IS NOT NULL DROP DATABASE TestDB;
CREATE DATABASE TestDB;
"
assert_contains "Create database" "$(run_sql "SELECT name FROM sys.databases WHERE name='TestDB'")" "TestDB"

run_sql "
USE TestDB;
CREATE TABLE Employees (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Name NVARCHAR(100) NOT NULL,
    Email NVARCHAR(200) NOT NULL,
    Created DATETIME2 DEFAULT GETDATE()
);
INSERT INTO Employees (Name, Email) VALUES
    ('Alice Johnson', 'alice@example.com'),
    ('Bob Smith', 'bob@example.com'),
    ('Carol White', 'carol@example.com');
"

result=$(run_sql "SELECT COUNT(*) FROM TestDB.dbo.Employees")
assert_contains "3 rows inserted" "${result}" "3"

result=$(run_sql "SELECT Name FROM TestDB.dbo.Employees WHERE Email='bob@example.com'")
assert_contains "Bob is in the table" "${result}" "Bob Smith"
echo ""

# ── Test 5: Stop and verify clean shutdown ────────────────────────────────────
echo "── Test 5: Stop container (clean shutdown) ──"
"${MSSQL_SH}" stop
sleep 2

# Confirm container is gone
if podman ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    red "  FAIL: Container still exists after stop"
    FAIL=$((FAIL + 1))
else
    green "  PASS: Container removed cleanly"
    PASS=$((PASS + 1))
fi
echo ""

# ── Test 6: Restart and verify data persisted ────────────────────────────────
echo "── Test 6: Restart and verify data persistence ──"
"${MSSQL_SH}" start

result=$(run_sql "SELECT name FROM sys.databases WHERE name='TestDB'")
assert_contains "TestDB still exists after restart" "${result}" "TestDB"

result=$(run_sql "SELECT COUNT(*) FROM TestDB.dbo.Employees")
assert_contains "3 rows still present" "${result}" "3"

result=$(run_sql "SELECT Name FROM TestDB.dbo.Employees WHERE Email='alice@example.com'")
assert_contains "Alice survived restart" "${result}" "Alice Johnson"

result=$(run_sql "SELECT Name FROM TestDB.dbo.Employees WHERE Email='carol@example.com'")
assert_contains "Carol survived restart" "${result}" "Carol White"

result=$(run_sql "SELECT status_desc FROM sys.dm_server_services WHERE servicename LIKE '%Agent%'")
assert_contains "SQL Server Agent running after restart" "${result}" "Running"
echo ""

# ── Test 7: Insert more data post-restart ─────────────────────────────────────
echo "── Test 7: Insert additional data after restart ──"
run_sql "INSERT INTO TestDB.dbo.Employees (Name, Email) VALUES ('Dave Lee', 'dave@example.com')"

result=$(run_sql "SELECT COUNT(*) FROM TestDB.dbo.Employees")
assert_contains "4 rows after new insert" "${result}" "4"
echo ""

# ── Test 8: Resource usage ────────────────────────────────────────────────────
echo "── Test 8: Resource check ──"
"${MSSQL_SH}" status
echo ""

# ── Test 9: Volume on disk ────────────────────────────────────────────────────
echo "── Test 9: Volume data on disk ──"
data_size=$(podman unshare du -sh "${SCRIPT_DIR}/volumes/data" 2>/dev/null | cut -f1)
if [[ -n "${data_size}" ]]; then
    green "  PASS: Volume directory has data (${data_size})"
    PASS=$((PASS + 1))
else
    red "  FAIL: Volume directory is empty"
    FAIL=$((FAIL + 1))
fi
echo ""

# ── Cleanup ──────────────────────────────────────────────────────────────────
echo "── Cleanup: dropping test database ──"
run_sql "DROP DATABASE TestDB" || true
"${MSSQL_SH}" stop
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "============================================"
echo " Results: ${PASS} passed, ${FAIL} failed"
echo "============================================"

if (( FAIL > 0 )); then
    exit 1
fi

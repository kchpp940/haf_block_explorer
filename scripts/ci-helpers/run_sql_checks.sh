#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Runs SQL checks including schema validation and regression tests.

OPTIONS:
    --output-dir=DIR           Output directory for artifacts (default: ./artifacts/sql-check)
    --logs-dir=DIR             Logs directory (default: ./logs/sql-check)
    --postgres-access=URL      PostgreSQL connection URL
    --help|-h                  Display this help screen and exit
EOF
}

OUTPUT_DIR="${CI_ARTIFACTS_DIR:-${PROJECT_ROOT}/artifacts}/sql-check"
LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/sql-check"
POSTGRES_ACCESS="postgresql://haf_admin@localhost:5432/haf_block_log"

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir=*) OUTPUT_DIR="${1#*=}" ;;
        --logs-dir=*) LOGS_DIR="${1#*=}" ;;
        --postgres-access=*) POSTGRES_ACCESS="${1#*=}" ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
    esac
    shift
done

mkdir -p "${OUTPUT_DIR}" "${LOGS_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOGS_DIR}/sql-check.log"
}

log_step() {
    echo "" | tee -a "${LOGS_DIR}/sql-check.log"
    echo "=== $1 ===" | tee -a "${LOGS_DIR}/sql-check.log"
}

run_psql() {
    psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on "$@" 2>&1 | tee -a "${LOGS_DIR}/sql-check.log"
}

generate_junit_report() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    local duration="$4"
    
    cat > "${OUTPUT_DIR}/${test_name}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sql_checks" tests="1" failures="$( [ "$status" = "FAILED" ] && echo 1 || echo 0 )" errors="0" skipped="0" time="${duration}">
  <testcase name="${test_name}" classname="sql_checks" time="${duration}">
    $( [ "$status" = "FAILED" ] && echo "<failure message=\"${message}\">${message}</failure>" || echo "" )
    <system-out><![CDATA[$(cat "${LOGS_DIR}/${test_name}.log" 2>/dev/null || echo "")]]></system-out>
  </testcase>
</testsuite>
EOF
}

log_step "SQL Checks Starting"
log "PostgreSQL: ${POSTGRES_ACCESS}"
log "Output directory: ${OUTPUT_DIR}"
log "Logs directory: ${LOGS_DIR}"

FAILED_TESTS=0
TOTAL_TESTS=0

# Test 1: Schema validation
log_step "Test 1: Schema Validation"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
START_TIME=$(date +%s)

SCHEMA_CHECK_LOG="${LOGS_DIR}/schema_validation.log"
> "$SCHEMA_CHECK_LOG"

{
    echo "Checking for required schemas..."
    REQUIRED_SCHEMAS=("hafd" "hafbe_app" "hafbe_endpoints" "hafbe_backend")
    for schema in "${REQUIRED_SCHEMAS[@]}"; do
        if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_namespace WHERE nspname='${schema}'" | grep -q 1; then
            echo "FAIL: Schema '${schema}' not found"
            exit 1
        fi
        echo "OK: Schema '${schema}' exists"
    done

    echo "Checking for required tables in hafbe_app..."
    REQUIRED_TABLES=("blocks" "accounts" "witnesses" "operations")
    for table in "${REQUIRED_TABLES[@]}"; do
        if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_tables WHERE schemaname='hafbe_app' AND tablename='${table}'" | grep -q 1; then
            echo "FAIL: Table 'hafbe_app.${table}' not found"
            exit 1
        fi
        echo "OK: Table 'hafbe_app.${table}' exists"
    done

    echo "Checking for required functions in hafbe_app..."
    REQUIRED_FUNCTIONS=("create_hafbe_indexes" "process_blocks")
    for func in "${REQUIRED_FUNCTIONS[@]}"; do
        if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_proc WHERE proname='${func}' AND pronamespace='hafbe_app'::regnamespace" | grep -q 1; then
            echo "FAIL: Function 'hafbe_app.${func}' not found"
            exit 1
        fi
        echo "OK: Function 'hafbe_app.${func}' exists"
    done
    
    echo "Schema validation passed!"
} > "$SCHEMA_CHECK_LOG" 2>&1 || true

DURATION=$(( $(date +%s) - START_TIME ))
if grep -q "FAIL:" "$SCHEMA_CHECK_LOG"; then
    log "Schema validation FAILED"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    generate_junit_report "schema_validation" "FAILED" "Schema validation failed" "$DURATION"
else
    log "Schema validation PASSED"
    generate_junit_report "schema_validation" "PASSED" "Schema validation passed" "$DURATION"
fi
cat "$SCHEMA_CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"

# Test 2: HAF contexts check
log_step "Test 2: HAF Contexts Check"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
START_TIME=$(date +%s)

CONTEXT_CHECK_LOG="${LOGS_DIR}/contexts_check.log"
> "$CONTEXT_CHECK_LOG"

{
    echo "Checking HAF contexts..."
    psql "$POSTGRES_ACCESS" -c "
        SELECT 
            name,
            current_block_num,
            irreversible_block,
            is_attached,
            last_active_at
        FROM hafd.contexts 
        WHERE name IN ('hafbe_app', 'hafbe_bal');
    "
    
    echo "Checking context states..."
    CONTEXTS_OK=true
    for ctx in hafbe_app hafbe_bal; do
        ATTACHED=$(psql "$POSTGRES_ACCESS" -qtAc "SELECT is_attached FROM hafd.contexts WHERE name='${ctx}'")
        if [ "$ATTACHED" != "t" ]; then
            echo "FAIL: Context '${ctx}' is not attached"
            CONTEXTS_OK=false
        else
            echo "OK: Context '${ctx}' is attached"
        fi
    done
    
    $CONTEXTS_OK && echo "Context check passed!" || echo "Context check failed!"
} > "$CONTEXT_CHECK_LOG" 2>&1 || true

DURATION=$(( $(date +%s) - START_TIME ))
if grep -q "FAIL:" "$CONTEXT_CHECK_LOG"; then
    log "HAF contexts check FAILED"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    generate_junit_report "contexts_check" "FAILED" "HAF contexts check failed" "$DURATION"
else
    log "HAF contexts check PASSED"
    generate_junit_report "contexts_check" "PASSED" "HAF contexts check passed" "$DURATION"
fi
cat "$CONTEXT_CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"

# Test 3: Data integrity basic check
log_step "Test 3: Basic Data Integrity Check"
TOTAL_TESTS=$((TOTAL_TESTS + 1))
START_TIME=$(date +%s)

DATA_CHECK_LOG="${LOGS_DIR}/data_integrity.log"
> "$DATA_CHECK_LOG"

{
    echo "Checking for NULL violations in critical columns..."
    
    NULL_CHECKS=(
        "hafbe_app.blocks:num"
        "hafbe_app.accounts:name"
        "hafbe_app.witnesses:name"
    )
    
    for check in "${NULL_CHECKS[@]}"; do
        table="${check%%:*}"
        column="${check##*:}"
        null_count=$(psql "$POSTGRES_ACCESS" -qtAc "SELECT COUNT(*) FROM ${table} WHERE ${column} IS NULL")
        if [ "$null_count" -gt 0 ]; then
            echo "FAIL: Table ${table} has ${null_count} NULL values in column ${column}"
        else
            echo "OK: Table ${table} has no NULL values in column ${column}"
        fi
    done
    
    echo "Data integrity check complete!"
} > "$DATA_CHECK_LOG" 2>&1 || true

DURATION=$(( $(date +%s) - START_TIME ))
if grep -q "FAIL:" "$DATA_CHECK_LOG"; then
    log "Data integrity check FAILED"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    generate_junit_report "data_integrity" "FAILED" "Data integrity check failed" "$DURATION"
else
    log "Data integrity check PASSED"
    generate_junit_report "data_integrity" "PASSED" "Data integrity check passed" "$DURATION"
fi
cat "$DATA_CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"

# Generate summary report
log_step "SQL Checks Summary"
log "Total tests: ${TOTAL_TESTS}"
log "Failed tests: ${FAILED_TESTS}"

cat > "${OUTPUT_DIR}/summary.txt" <<EOF
SQL Checks Summary
==================
Date: $(date)
Total tests: ${TOTAL_TESTS}
Failed tests: ${FAILED_TESTS}
Status: $( [ "$FAILED_TESTS" -eq 0 ] && echo "PASSED" || echo "FAILED" )
EOF

if [ "$FAILED_TESTS" -gt 0 ]; then
    log "SQL checks FAILED with ${FAILED_TESTS} failures"
    exit 1
fi

log "SQL checks PASSED"
exit 0

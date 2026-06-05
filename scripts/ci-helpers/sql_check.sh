#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

SQL Installation and Schema Check for CI - validates SQL setup, schema, contexts and tables.
Does NOT run regression tests - use run_test.sh for that.

OPTIONS:
    --postgres-access=URL      PostgreSQL connection URL
    --output-dir=DIR           Output directory for artifacts (default: ./artifacts/sql-check)
    --logs-dir=DIR             Logs directory (default: ./logs/sql-check)
    --generate-junit           Generate JUnit XML report
    --help|-h                  Display this help screen and exit
EOF
}

POSTGRES_ACCESS="postgresql://haf_admin@localhost:5432/haf_block_log"
OUTPUT_DIR="${CI_ARTIFACTS_DIR:-${PROJECT_ROOT}/artifacts}/sql-check"
LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/sql-check"
GENERATE_JUNIT=true

while [ $# -gt 0 ]; do
    case "$1" in
        --postgres-access=*) POSTGRES_ACCESS="${1#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}" ;;
        --logs-dir=*) LOGS_DIR="${1#*=}" ;;
        --no-junit) GENERATE_JUNIT=false ;;
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
    psql "$POSTGRES_ACCESS" -v ON_ERROR_STOP=on "$@" 2>&1
}

generate_junit() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    local duration="$4"
    local failures="0"
    
    [ "$status" = "FAILED" ] && failures="1"
    
    cat > "${OUTPUT_DIR}/${test_name}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="sql_check" tests="1" failures="${failures}" errors="0" skipped="0" time="${duration}">
  <testcase name="${test_name}" classname="sql_check" time="${duration}">
    $( [ "$status" = "FAILED" ] && echo "<failure message=\"${message}\">${message}</failure>" || echo "" )
    <system-out><![CDATA[$(cat "${LOGS_DIR}/${test_name}.log" 2>/dev/null || echo "")]]></system-out>
  </testcase>
</testsuite>
EOF
}

FAILED_CHECKS=0
TOTAL_CHECKS=0

# =============================================================================
# Check 1: HAF Installation Verification
# =============================================================================
check_haf_installation() {
    local CHECK_NAME="haf_installation"
    local CHECK_LOG="${LOGS_DIR}/${CHECK_NAME}.log"
    local START_TIME=$(date +%s)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_step "Check 1: HAF Installation"
    > "$CHECK_LOG"
    
    {
        echo "Checking HAF database existence..."
        if ! psql "$POSTGRES_ACCESS" -c "\l" 2>/dev/null | grep -q "haf_block_log"; then
            echo "FAIL: HAF database 'haf_block_log' not found"
            exit 1
        fi
        echo "OK: HAF database exists"
        
        echo ""
        echo "Checking HAF schema 'hafd'..."
        if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_namespace WHERE nspname='hafd'" | grep -q 1; then
            echo "FAIL: HAF schema 'hafd' not found"
            exit 1
        fi
        echo "OK: HAF schema 'hafd' exists"
        
        echo ""
        echo "Checking HAF contexts table..."
        if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM hafd.contexts LIMIT 1" | grep -q 1; then
            echo "FAIL: HAF contexts table not accessible"
            exit 1
        fi
        echo "OK: HAF contexts table is accessible"
        
        echo ""
        echo "HAF installation verified!"
    } > "$CHECK_LOG" 2>&1 || true
    
    local DURATION=$(( $(date +%s) - START_TIME ))
    cat "$CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"
    
    if grep -q "FAIL:" "$CHECK_LOG"; then
        log "FAIL: HAF installation check"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "FAILED" "HAF installation check failed" "$DURATION"
        return 1
    else
        log "PASS: HAF installation check"
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "PASSED" "HAF installation verified" "$DURATION"
        return 0
    fi
}

# =============================================================================
# Check 2: HAFAH Installation Verification
# =============================================================================
check_hafah_installation() {
    local CHECK_NAME="hafah_installation"
    local CHECK_LOG="${LOGS_DIR}/${CHECK_NAME}.log"
    local START_TIME=$(date +%s)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_step "Check 2: HAFAH Installation"
    > "$CHECK_LOG"
    
    {
        echo "Checking HAFAH schemas..."
        local REQUIRED_SCHEMAS=("hive" "hivemind_app")
        for schema in "${REQUIRED_SCHEMAS[@]}"; do
            if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_namespace WHERE nspname='${schema}'" | grep -q 1; then
                echo "FAIL: HAFAH schema '${schema}' not found"
                exit 1
            fi
            echo "OK: HAFAH schema '${schema}' exists"
        done
        
        echo ""
        echo "HAFAH installation verified!"
    } > "$CHECK_LOG" 2>&1 || true
    
    local DURATION=$(( $(date +%s) - START_TIME ))
    cat "$CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"
    
    if grep -q "FAIL:" "$CHECK_LOG"; then
        log "FAIL: HAFAH installation check"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "FAILED" "HAFAH installation check failed" "$DURATION"
        return 1
    else
        log "PASS: HAFAH installation check"
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "PASSED" "HAFAH installation verified" "$DURATION"
        return 0
    fi
}

# =============================================================================
# Check 3: HAFBE Application Installation
# =============================================================================
check_hafbe_installation() {
    local CHECK_NAME="hafbe_installation"
    local CHECK_LOG="${LOGS_DIR}/${CHECK_NAME}.log"
    local START_TIME=$(date +%s)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_step "Check 3: HAFBE Application Installation"
    > "$CHECK_LOG"
    
    {
        echo "Checking HAFBE schemas..."
        local REQUIRED_SCHEMAS=("hafbe_app" "hafbe_endpoints" "hafbe_backend")
        for schema in "${REQUIRED_SCHEMAS[@]}"; do
            if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_namespace WHERE nspname='${schema}'" | grep -q 1; then
                echo "FAIL: HAFBE schema '${schema}' not found"
                exit 1
            fi
            echo "OK: HAFBE schema '${schema}' exists"
        done
        
        echo ""
        echo "HAFBE installation verified!"
    } > "$CHECK_LOG" 2>&1 || true
    
    local DURATION=$(( $(date +%s) - START_TIME ))
    cat "$CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"
    
    if grep -q "FAIL:" "$CHECK_LOG"; then
        log "FAIL: HAFBE installation check"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "FAILED" "HAFBE installation check failed" "$DURATION"
        return 1
    else
        log "PASS: HAFBE installation check"
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "PASSED" "HAFBE installation verified" "$DURATION"
        return 0
    fi
}

# =============================================================================
# Check 4: HAF Contexts State
# =============================================================================
check_haf_contexts() {
    local CHECK_NAME="haf_contexts"
    local CHECK_LOG="${LOGS_DIR}/${CHECK_NAME}.log"
    local START_TIME=$(date +%s)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_step "Check 4: HAF Contexts State"
    > "$CHECK_LOG"
    
    {
        echo "Checking HAF contexts..."
        psql "$POSTGRES_ACCESS" -c "
            SELECT 
                name,
                current_block_num,
                irreversible_block,
                is_attached,
                state,
                last_active_at
            FROM hafd.contexts 
            ORDER BY name;
        "
        
        echo ""
        echo "Verifying required contexts are attached..."
        local REQUIRED_CONTEXTS=("hafbe_app" "hafbe_bal")
        for ctx in "${REQUIRED_CONTEXTS[@]}"; do
            local ATTACHED=$(psql "$POSTGRES_ACCESS" -qtAc "SELECT is_attached FROM hafd.contexts WHERE name='${ctx}'")
            if [ "$ATTACHED" != "t" ]; then
                echo "FAIL: Context '${ctx}' is not attached"
                exit 1
            fi
            echo "OK: Context '${ctx}' is attached"
        done
        
        echo ""
        echo "HAF contexts verified!"
    } > "$CHECK_LOG" 2>&1 || true
    
    local DURATION=$(( $(date +%s) - START_TIME ))
    cat "$CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"
    
    if grep -q "FAIL:" "$CHECK_LOG"; then
        log "FAIL: HAF contexts check"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "FAILED" "HAF contexts check failed" "$DURATION"
        return 1
    else
        log "PASS: HAF contexts check"
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "PASSED" "HAF contexts verified" "$DURATION"
        return 0
    fi
}

# =============================================================================
# Check 5: Critical Tables Existence
# =============================================================================
check_critical_tables() {
    local CHECK_NAME="critical_tables"
    local CHECK_LOG="${LOGS_DIR}/${CHECK_NAME}.log"
    local START_TIME=$(date +%s)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_step "Check 5: Critical Tables Existence"
    > "$CHECK_LOG"
    
    {
        echo "Checking HAFBE critical tables..."
        local CRITICAL_TABLES=(
            "hafbe_app.blocks"
            "hafbe_app.accounts"
            "hafbe_app.operations"
            "hafbe_app.transactions"
        )
        
        for table in "${CRITICAL_TABLES[@]}"; do
            local schema="${table%%.*}"
            local tablename="${table##*.}"
            if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_tables WHERE schemaname='${schema}' AND tablename='${tablename}'" | grep -q 1; then
                echo "FAIL: Critical table '${table}' not found"
                exit 1
            fi
            echo "OK: Critical table '${table}' exists"
        done
        
        echo ""
        echo "Critical tables verified!"
    } > "$CHECK_LOG" 2>&1 || true
    
    local DURATION=$(( $(date +%s) - START_TIME ))
    cat "$CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"
    
    if grep -q "FAIL:" "$CHECK_LOG"; then
        log "FAIL: Critical tables check"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "FAILED" "Critical tables check failed" "$DURATION"
        return 1
    else
        log "PASS: Critical tables check"
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "PASSED" "Critical tables verified" "$DURATION"
        return 0
    fi
}

# =============================================================================
# Check 6: Required Functions
# =============================================================================
check_required_functions() {
    local CHECK_NAME="required_functions"
    local CHECK_LOG="${LOGS_DIR}/${CHECK_NAME}.log"
    local START_TIME=$(date +%s)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    log_step "Check 6: Required Functions"
    > "$CHECK_LOG"
    
    {
        echo "Checking required RPC functions..."
        local REQUIRED_FUNCTIONS=(
            "hafbe_endpoints.get_latest_blocks"
            "hafbe_endpoints.get_hafbe_version"
        )
        
        for func in "${REQUIRED_FUNCTIONS[@]}"; do
            local schema="${func%%.*}"
            local funcname="${func##*.}"
            if ! psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_proc WHERE proname='${funcname}' AND pronamespace='${schema}'::regnamespace" | grep -q 1; then
                echo "FAIL: Required function '${func}' not found"
                exit 1
            fi
            echo "OK: Required function '${func}' exists"
        done
        
        echo ""
        echo "Required functions verified!"
    } > "$CHECK_LOG" 2>&1 || true
    
    local DURATION=$(( $(date +%s) - START_TIME ))
    cat "$CHECK_LOG" >> "${LOGS_DIR}/sql-check.log"
    
    if grep -q "FAIL:" "$CHECK_LOG"; then
        log "FAIL: Required functions check"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "FAILED" "Required functions check failed" "$DURATION"
        return 1
    else
        log "PASS: Required functions check"
        [ "$GENERATE_JUNIT" = true ] && generate_junit "$CHECK_NAME" "PASSED" "Required functions verified" "$DURATION"
        return 0
    fi
}

# =============================================================================
# Main execution
# =============================================================================
log_step "SQL Check Starting"
log "PostgreSQL: ${POSTGRES_ACCESS}"
log "Output directory: ${OUTPUT_DIR}"
log "Logs directory: ${LOGS_DIR}"
log "Generate JUnit: ${GENERATE_JUNIT}"

# Run all checks
check_haf_installation || true
check_hafah_installation || true
check_hafbe_installation || true
check_haf_contexts || true
check_critical_tables || true
check_required_functions || true

# Generate summary
log_step "SQL Check Summary"
log "Total checks: ${TOTAL_CHECKS}"
log "Failed checks: ${FAILED_CHECKS}"

cat > "${OUTPUT_DIR}/summary.txt" <<EOF
SQL Check Summary
=================
Date: $(date)
Total checks: ${TOTAL_CHECKS}
Failed checks: ${FAILED_CHECKS}
Status: $( [ "$FAILED_CHECKS" -eq 0 ] && echo "PASSED" || echo "FAILED" )
EOF

cat "${OUTPUT_DIR}/summary.txt" | tee -a "${LOGS_DIR}/sql-check.log"

if [ "$FAILED_CHECKS" -gt 0 ]; then
    log_step "SQL Check FAILED"
    exit 1
fi

log_step "SQL Check PASSED"
exit 0

#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 --test-type=TYPE [OPTIONS]

Unified test runner for CI pipeline.

TEST TYPES:
    sql-check              Run SQL schema and integrity checks
    api-regression         Run Tavern API regression tests
    performance-smoke      Run performance smoke tests

OPTIONS:
    --output-dir=DIR       Output directory for artifacts (default: ./artifacts/\$TEST_TYPE)
    --logs-dir=DIR         Logs directory (default: ./logs/\$TEST_TYPE)
    --postgres-access=URL  PostgreSQL connection URL
    --postgrest-url=URL    PostgREST URL
    --help|-h              Display this help screen and exit
EOF
}

TEST_TYPE=""
OUTPUT_DIR=""
LOGS_DIR=""
POSTGRES_ACCESS="postgresql://haf_admin@localhost:5432/haf_block_log"
POSTGREST_URL="http://localhost:3000"

while [ $# -gt 0 ]; do
    case "$1" in
        --test-type=*) TEST_TYPE="${1#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}" ;;
        --logs-dir=*) LOGS_DIR="${1#*=}" ;;
        --postgres-access=*) POSTGRES_ACCESS="${1#*=}" ;;
        --postgrest-url=*) POSTGREST_URL="${1#*=}" ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
    esac
    shift
done

if [ -z "$TEST_TYPE" ]; then
    echo "ERROR: --test-type is required"
    print_help
    exit 2
fi

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${CI_ARTIFACTS_DIR:-${PROJECT_ROOT}/artifacts}/${TEST_TYPE}"
fi

if [ -z "$LOGS_DIR" ]; then
    LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/${TEST_TYPE}"
fi

mkdir -p "${OUTPUT_DIR}" "${LOGS_DIR}"

echo "=============================================="
echo "CI Test Runner"
echo "=============================================="
echo "Test Type: ${TEST_TYPE}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "Logs Directory: ${LOGS_DIR}"
echo "=============================================="
echo ""

case "$TEST_TYPE" in
    sql-check)
        exec "${SCRIPT_DIR}/run_sql_checks.sh" \
            --output-dir="${OUTPUT_DIR}" \
            --logs-dir="${LOGS_DIR}" \
            --postgres-access="${POSTGRES_ACCESS}"
        ;;
    api-regression)
        exec "${SCRIPT_DIR}/run_api_regression.sh" \
            --output-dir="${OUTPUT_DIR}" \
            --logs-dir="${LOGS_DIR}" \
            --postgrest-url="${POSTGREST_URL}"
        ;;
    performance-smoke)
        exec "${SCRIPT_DIR}/run_performance_smoke.sh" \
            --output-dir="${OUTPUT_DIR}" \
            --logs-dir="${LOGS_DIR}" \
            --postgrest-url="${POSTGREST_URL}"
        ;;
    *)
        echo "ERROR: Unknown test type: ${TEST_TYPE}"
        echo "Valid types: sql-check, api-regression, performance-smoke"
        exit 2
        ;;
esac

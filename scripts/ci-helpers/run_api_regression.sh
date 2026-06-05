#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Runs Tavern API regression tests.

OPTIONS:
    --output-dir=DIR           Output directory for artifacts (default: ./artifacts/api-regression)
    --logs-dir=DIR             Logs directory (default: ./logs/api-regression)
    --postgrest-url=URL        PostgREST URL (default: http://localhost:3000)
    --test-pattern=PATTERN     Optional pattern to filter tests (default: all)
    --help|-h                  Display this help screen and exit
EOF
}

OUTPUT_DIR="${CI_ARTIFACTS_DIR:-${PROJECT_ROOT}/artifacts}/api-regression"
LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/api-regression"
POSTGREST_URL="http://localhost:3000"
TEST_PATTERN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir=*) OUTPUT_DIR="${1#*=}" ;;
        --logs-dir=*) LOGS_DIR="${1#*=}" ;;
        --postgrest-url=*) POSTGREST_URL="${1#*=}" ;;
        --test-pattern=*) TEST_PATTERN="${1#*=}" ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
    esac
    shift
done

mkdir -p "${OUTPUT_DIR}" "${LOGS_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOGS_DIR}/api-regression.log"
}

log_step() {
    echo "" | tee -a "${LOGS_DIR}/api-regression.log"
    echo "=== $1 ===" | tee -a "${LOGS_DIR}/api-regression.log"
}

log_step "API Regression Tests Starting"
log "PostgREST URL: ${POSTGREST_URL}"
log "Output directory: ${OUTPUT_DIR}"
log "Logs directory: ${LOGS_DIR}"
log "Test pattern: ${TEST_PATTERN:-all}"

# Wait for PostgREST to be ready
log_step "Waiting for PostgREST to be ready"
MAX_RETRIES=30
RETRY_COUNT=0
while [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
    if curl -s -f "${POSTGREST_URL}/" > /dev/null 2>&1; then
        log "PostgREST is ready"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ "$RETRY_COUNT" -eq "$MAX_RETRIES" ]; then
        log "ERROR: PostgREST did not become ready in time"
        curl -v "${POSTGREST_URL}/" 2>&1 | tee -a "${LOGS_DIR}/api-regression.log" || true
        exit 1
    fi
    sleep 2
done

# Check if tavern is available
if ! command -v tavern-ci &> /dev/null; then
    log "Installing tavern..."
    pip install tavern[pytest] --quiet
fi

log_step "Running Tavern API tests"

TAVERN_TEST_DIR="${PROJECT_ROOT}/tests/tavern"
if [ ! -d "$TAVERN_TEST_DIR" ]; then
    log "ERROR: Tavern test directory not found at ${TAVERN_TEST_DIR}"
    exit 1
fi

cd "${PROJECT_ROOT}"

# Create tavern config
cat > "${OUTPUT_DIR}/tavern-common.yaml" <<EOF
---
test_name: Common configuration for HAFBE API tests
variables:
  api_url: "${POSTGREST_URL}"
strict: true
EOF

# Collect test files
TEST_FILES=()
if [ -n "$TEST_PATTERN" ]; then
    mapfile -t TEST_FILES < <(find "$TAVERN_TEST_DIR" -name "*.tavern.yaml" -path "*${TEST_PATTERN}*" | sort)
else
    mapfile -t TEST_FILES < <(find "$TAVERN_TEST_DIR" -name "*.tavern.yaml" | sort)
fi

log "Found ${#TEST_FILES[@]} test files"

TOTAL_TESTS=0
FAILED_TESTS=0
PASSED_TESTS=0

# Run each test file
for TEST_FILE in "${TEST_FILES[@]}"; do
    TEST_NAME=$(basename "$TEST_FILE" .tavern.yaml)
    TEST_REL_PATH="${TEST_FILE#${PROJECT_DIR}/}"
    
    log "Running test: ${TEST_NAME}"
    
    # Create test-specific config
    TEST_CONFIG="${OUTPUT_DIR}/${TEST_NAME}-config.yaml"
    cp "${OUTPUT_DIR}/tavern-common.yaml" "$TEST_CONFIG"
    
    # Run the test
    TEST_LOG="${LOGS_DIR}/${TEST_NAME}.log"
    if tavern-ci "$TEST_FILE" \
        --tavern-global-cfg "$TEST_CONFIG" \
        --junit-xml "${OUTPUT_DIR}/${TEST_NAME}.xml" \
        --html "${OUTPUT_DIR}/${TEST_NAME}.html" \
        --self-contained-html \
        -v 2>&1 | tee "$TEST_LOG"; then
        log "PASSED: ${TEST_NAME}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        log "FAILED: ${TEST_NAME}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
done

# Generate combined JUnit report
log_step "Generating combined report"

# Merge all JUnit files if we have multiple
if [ "$TOTAL_TESTS" -gt 0 ] && command -v junitparser &> /dev/null; then
    JUNIT_FILES=("${OUTPUT_DIR}"/*.xml)
    if [ "${#JUNIT_FILES[@]}" -gt 1 ]; then
        python3 -c "
import sys
from junitparser import JUnitXml, TestSuite, Failure

combined = TestSuite('api_regression')
total_tests = 0
total_failures = 0
total_time = 0

for f in sys.argv[1:]:
    try:
        xml = JUnitXml.fromfile(f)
        for suite in xml:
            for case in suite:
                combined.add_testcase(case)
                total_tests += 1
                total_time += case.time or 0
                if case.result and any(isinstance(r, Failure) for r in case.result):
                    total_failures += 1
    except Exception as e:
        print(f'Warning: Could not parse {f}: {e}', file=sys.stderr)

combined.tests = total_tests
combined.failures = total_failures
combined.time = total_time

xml_out = JUnitXml()
xml_out.add_testsuite(combined)
xml_out.write('${OUTPUT_DIR}/api-regression-combined.xml')
" "${JUNIT_FILES[@]}" 2>/dev/null || true
    fi
fi

# Generate summary
cat > "${OUTPUT_DIR}/summary.txt" <<EOF
API Regression Test Summary
============================
Date: $(date)
PostgREST URL: ${POSTGREST_URL}
Total test files: ${TOTAL_TESTS}
Passed: ${PASSED_TESTS}
Failed: ${FAILED_TESTS}
Status: $( [ "$FAILED_TESTS" -eq 0 ] && echo "PASSED" || echo "FAILED" )
EOF

cat "${OUTPUT_DIR}/summary.txt" | tee -a "${LOGS_DIR}/api-regression.log"

log_step "API Regression Tests Complete"

if [ "$FAILED_TESTS" -gt 0 ]; then
    log "API regression tests FAILED with ${FAILED_TESTS} failures"
    exit 1
fi

log "API regression tests PASSED"
exit 0

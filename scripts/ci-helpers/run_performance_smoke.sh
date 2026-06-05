#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Runs performance smoke tests (k6 or JMeter smoke profile).

OPTIONS:
    --output-dir=DIR           Output directory for artifacts (default: ./artifacts/performance-smoke)
    --logs-dir=DIR             Logs directory (default: ./logs/performance-smoke)
    --postgrest-url=URL        PostgREST URL (default: http://localhost:3000)
    --duration=DURATION        Test duration (default: 30s)
    --vus=NUM                  Virtual users (default: 5)
    --help|-h                  Display this help screen and exit
EOF
}

OUTPUT_DIR="${CI_ARTIFACTS_DIR:-${PROJECT_ROOT}/artifacts}/performance-smoke"
LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/performance-smoke"
POSTGREST_URL="http://localhost:3000"
TEST_DURATION="30s"
VUS="5"

while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir=*) OUTPUT_DIR="${1#*=}" ;;
        --logs-dir=*) LOGS_DIR="${1#*=}" ;;
        --postgrest-url=*) POSTGREST_URL="${1#*=}" ;;
        --duration=*) TEST_DURATION="${1#*=}" ;;
        --vus=*) VUS="${1#*=}" ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
    esac
    shift
done

mkdir -p "${OUTPUT_DIR}" "${LOGS_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOGS_DIR}/performance-smoke.log"
}

log_step() {
    echo "" | tee -a "${LOGS_DIR}/performance-smoke.log"
    echo "=== $1 ===" | tee -a "${LOGS_DIR}/performance-smoke.log"
}

generate_junit_report() {
    local test_name="$1"
    local status="$2"
    local duration="$3"
    local avg_response_time="$4"
    local p95_response_time="$5"
    local success_rate="$6"
    
    local failures="0"
    local message="Performance test passed"
    
    if [ "$status" = "FAILED" ]; then
        failures="1"
        message="Performance test failed - success rate below threshold"
    fi
    
    cat > "${OUTPUT_DIR}/${test_name}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="performance_smoke" tests="1" failures="${failures}" errors="0" skipped="0" time="${duration}">
  <testcase name="${test_name}" classname="performance" time="${duration}">
    $( [ "$status" = "FAILED" ] && echo "<failure message=\"${message}\">${message}</failure>" || echo "" )
    <system-out><![CDATA[
PostgREST URL: ${POSTGREST_URL}
Virtual Users: ${VUS}
Duration: ${TEST_DURATION}
Average Response Time: ${avg_response_time}ms
p95 Response Time: ${p95_response_time}ms
Success Rate: ${success_rate}%
    ]]></system-out>
  </testcase>
</testsuite>
EOF
}

log_step "Performance Smoke Tests Starting"
log "PostgREST URL: ${POSTGREST_URL}"
log "Output directory: ${OUTPUT_DIR}"
log "Logs directory: ${LOGS_DIR}"
log "Virtual Users: ${VUS}"
log "Duration: ${TEST_DURATION}"

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
        exit 1
    fi
    sleep 2
done

# Define test endpoints
ENDPOINTS=(
    "get_latest_blocks:${POSTGREST_URL}/rpc/get_latest_blocks?limit=10"
    "get_hafbe_version:${POSTGREST_URL}/rpc/get_hafbe_version"
)

# Check if k6 is available, otherwise use curl-based simple test
if command -v k6 &> /dev/null; then
    log "Using k6 for performance testing"
    
    # Create k6 test script
    cat > "${OUTPUT_DIR}/smoke-test.js" <<EOF
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
    vus: ${VUS},
    duration: '${TEST_DURATION}',
    thresholds: {
        http_req_duration: ['p(95)<2000'],
        http_req_failed: ['rate<0.05'],
    },
};

const ENDPOINTS = [
    '${POSTGREST_URL}/rpc/get_latest_blocks?limit=10',
    '${POSTGREST_URL}/rpc/get_hafbe_version',
];

export default function () {
    const endpoint = ENDPOINTS[Math.floor(Math.random() * ENDPOINTS.length)];
    const res = http.get(endpoint, { timeout: '30s' });
    
    check(res, {
        'status is 200': (r) => r.status === 200,
        'response time < 5s': (r) => r.timings.duration < 5000,
    });
    
    sleep(1);
}
EOF

    # Run k6
    START_TIME=$(date +%s)
    if k6 run "${OUTPUT_DIR}/smoke-test.js" \
        --out json="${OUTPUT_DIR}/k6-results.json" \
        --summary-export="${OUTPUT_DIR}/k6-summary.json" \
        2>&1 | tee "${LOGS_DIR}/k6.log"; then
        TEST_STATUS="PASSED"
    else
        TEST_STATUS="FAILED"
    fi
    DURATION=$(( $(date +%s) - START_TIME ))

    # Extract metrics
    if [ -f "${OUTPUT_DIR}/k6-summary.json" ]; then
        AVG_RT=$(python3 -c "import json; d=json.load(open('${OUTPUT_DIR}/k6-summary.json')); print(d.get('metrics',{}).get('http_req_duration',{}).get('avg',0))" 2>/dev/null || echo "0")
        P95_RT=$(python3 -c "import json; d=json.load(open('${OUTPUT_DIR}/k6-summary.json')); print(d.get('metrics',{}).get('http_req_duration',{}).get('p(95)',0))" 2>/dev/null || echo "0")
        SUCCESS_RATE=$(python3 -c "import json; d=json.load(open('${OUTPUT_DIR}/k6-summary.json')); failed=d.get('metrics',{}).get('http_req_failed',{}).get('rate',1); print(round((1-failed)*100,2))" 2>/dev/null || echo "0")
    else
        AVG_RT="0"
        P95_RT="0"
        SUCCESS_RATE="0"
    fi

else
    log "k6 not found, using simple curl-based test"
    
    # Simple curl-based test
    START_TIME=$(date +%s)
    TOTAL_REQUESTS=0
    SUCCESS_REQUESTS=0
    TOTAL_TIME=0
    MAX_TIME=0
    
    for ((i=0; i<20; i++)); do
        for endpoint_info in "${ENDPOINTS[@]}"; do
            name="${endpoint_info%%:*}"
            url="${endpoint_info#*:}"
            
            START_REQ=$(date +%s%N)
            if curl -s -f -o /dev/null -w "%{http_code}" "$url" | grep -q "200"; then
                SUCCESS_REQUESTS=$((SUCCESS_REQUESTS + 1))
                END_REQ=$(date +%s%N)
                ELAPSED=$(( (END_REQ - START_REQ) / 1000000 ))
                TOTAL_TIME=$((TOTAL_TIME + ELAPSED))
                if [ "$ELAPSED" -gt "$MAX_TIME" ]; then
                    MAX_TIME=$ELAPSED
                fi
                log "  OK: ${name} (${ELAPSED}ms)"
            else
                log "  FAIL: ${name}"
            fi
            TOTAL_REQUESTS=$((TOTAL_REQUESTS + 1))
            sleep 0.5
        done
    done
    
    DURATION=$(( $(date +%s) - START_TIME ))
    
    if [ "$TOTAL_REQUESTS" -gt 0 ]; then
        SUCCESS_RATE=$((SUCCESS_REQUESTS * 100 / TOTAL_REQUESTS))
        AVG_RT=$((TOTAL_TIME / TOTAL_REQUESTS))
        P95_RT=$MAX_TIME
    else
        SUCCESS_RATE=0
        AVG_RT=0
        P95_RT=0
    fi
    
    if [ "$SUCCESS_RATE" -ge 95 ]; then
        TEST_STATUS="PASSED"
    else
        TEST_STATUS="FAILED"
    fi
    
    cat > "${OUTPUT_DIR}/results.txt" <<EOF
Performance Smoke Test Results
===============================
Total Requests: ${TOTAL_REQUESTS}
Successful Requests: ${SUCCESS_REQUESTS}
Success Rate: ${SUCCESS_RATE}%
Average Response Time: ${AVG_RT}ms
Max Response Time: ${MAX_TIME}ms
EOF
fi

# Generate JUnit report
generate_junit_report "performance_smoke" "$TEST_STATUS" "$DURATION" "$AVG_RT" "$P95_RT" "$SUCCESS_RATE"

# Generate summary
cat > "${OUTPUT_DIR}/summary.txt" <<EOF
Performance Smoke Test Summary
===============================
Date: $(date)
PostgREST URL: ${POSTGREST_URL}
Virtual Users: ${VUS}
Duration: ${TEST_DURATION}
Average Response Time: ${AVG_RT}ms
p95 Response Time: ${P95_RT}ms
Success Rate: ${SUCCESS_RATE}%
Status: ${TEST_STATUS}
EOF

cat "${OUTPUT_DIR}/summary.txt" | tee -a "${LOGS_DIR}/performance-smoke.log"

log_step "Performance Smoke Tests Complete"

if [ "$TEST_STATUS" = "FAILED" ]; then
    log "Performance smoke tests FAILED"
    exit 1
fi

log "Performance smoke tests PASSED"
exit 0

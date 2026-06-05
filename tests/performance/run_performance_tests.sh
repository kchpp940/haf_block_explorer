#!/bin/bash

set -e
set -o pipefail

print_help () {
cat <<EOF 
    Usage: $0 [OPTION[=VALUE]]...

    Runs performance tests.
    OPTIONS:
    --postgresql-host=HOST           PostgreSQL host (defaults to localhost)
    --postgresql-port=PORT           PostgreSQL port (defaults to 5432)
    --postgresql-user=USER           PostgreSQL user (defaults to haf_admin)
    --postgresql-password=PASSWORD   PostgreSQL password (empty by default)
    --postgresql-database=NAME       PostgreSQL database (defaults to haf_block_log)
    --database-size=NUMBER           Database size to generate (defaults to 1000)
    --postgrest-host=HOST            PostgREST host (defaults to localhost)
    --postgrest-port=PORT            PostgREST port (defaults to 3000)
    --test-thread-count=NUMBER       Number of threads to use to run tests (defaults to 8)
    --test-loop-count=NUMBER         Number of test loops (defaults to 60)
    --smoke                          Enable smoke test mode (short duration, low concurrency)
    --smoke-threshold-time=MS        Smoke test max average response time in ms (defaults to 2000)
    --smoke-threshold-success=RATE   Smoke test min success rate percentage (defaults to 95)
    --no-fail-on-threshold           Do not fail on threshold violation (report only)
    --help|-h|-?                     Display this help screen and exit
EOF
}

POSTGRESQL_HOST=${POSTGRESQL_HOST:-"localhost"}
POSTGRESQL_PORT=${POSTGRESQL_PORT:-"5432"}
POSTGRESQL_USER=${POSTGRESQL_USER:-"haf_admin"}
POSTGRESQL_PASSWORD=${POSTGRESQL_PASSWORD:-""}
POSTGRESQL_DATABASE=${POSTGRESQL_DATABASE:-"haf_block_log"}
DATABASE_SIZE=${DATABASE_SIZE:-"1000"}
POSTGREST_HOST=${POSTGREST_HOST:-"localhost"}
POSTGREST_PORT=${POSTGREST_PORT:-"3000"}
TEST_THREAD_COUNT=${TEST_THREAD_COUNT:-"8"}
TEST_LOOP_COUNT=${TEST_LOOP_COUNT:-"60"}
SMOKE_MODE=false
SMOKE_THRESHOLD_TIME=${SMOKE_THRESHOLD_TIME:-"2000"}
SMOKE_THRESHOLD_SUCCESS=${SMOKE_THRESHOLD_SUCCESS:-"95"}
FAIL_ON_THRESHOLD=true
TEST_ROOT_DIRECTORY="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

while [ $# -gt 0 ]; do
  case "$1" in
    --postgresql-host=*)
        POSTGRESQL_HOST="${1#*=}"
        ;;
    --postgresql-port=*)
        POSTGRESQL_PORT="${1#*=}"
        ;;
    --postgresql-user=*)
        POSTGRESQL_USER="${1#*=}"
        ;;
    --postgresql-password=*)
        POSTGRESQL_PASSWORD="${1#*=}"
        ;;
    --postgresql-database=*)
        POSTGRESQL_DATABASE="${1#*=}"
        ;;
    --database-size=*)
        DATABASE_SIZE="${1#*=}"
        ;; 
    --postgrest-host=*)
        POSTGREST_HOST="${1#*=}"
        ;;
    --postgrest-port=*)
        POSTGREST_PORT="${1#*=}"
        ;;
    --test-thread-count=*)
        TEST_THREAD_COUNT="${1#*=}"
        ;;
    --test-loop-count=*)
        TEST_LOOP_COUNT="${1#*=}"
        ;;
    --smoke)
        SMOKE_MODE=true
        ;;
    --smoke-threshold-time=*)
        SMOKE_THRESHOLD_TIME="${1#*=}"
        ;;
    --smoke-threshold-success=*)
        SMOKE_THRESHOLD_SUCCESS="${1#*=}"
        ;;
    --no-fail-on-threshold)
        FAIL_ON_THRESHOLD=false
        ;;
    --help|-h|-?)
        print_help
        exit 0
        ;;
    -*)
        echo -e "ERROR: '$1' is not a valid option\n"
        print_help
        exit 1
        ;;
    *)
        echo -e "ERROR: '$1' is not a valid argument\n"
        print_help
        exit 2
        ;;
    esac
    shift
done

if [ "$SMOKE_MODE" = true ]; then
    echo "=== Smoke Test Mode Enabled ==="
    echo "  Thread count: 2 (smoke override)"
    echo "  Loop count: 5 (smoke override)"
    echo "  Database size: 100 (smoke override)"
    echo "  Threshold - Max avg response time: ${SMOKE_THRESHOLD_TIME}ms"
    echo "  Threshold - Min success rate: ${SMOKE_THRESHOLD_SUCCESS}%"
    echo ""
    TEST_THREAD_COUNT=2
    TEST_LOOP_COUNT=5
    DATABASE_SIZE=100
fi

cleanup() {
  local result_dir="$TEST_ROOT_DIRECTORY/result"
  local result_report_dir="$result_dir/result_report"

  if [[ -z "${CI:-}" ]]; then
    echo "This will delete previous test result!"
    echo "Press ENTER to continue, ^C to cancel."
    read -r _
  fi

  rm -rf "$result_dir"
  mkdir -p "$result_dir"
  mkdir -p "$result_report_dir"
}

generate_db() {
  local port="$1"
  local host="$2"
  local user="$3"
  local password="$4"
  local database="$5"
  local database_size="$6"
  python3 "$TEST_ROOT_DIRECTORY/generate_db.py" \
    --port "$port" \
    --host "$host" \
    --user "$user" \
    --password "$password" \
    --database "$database" \
    --database-size "$database_size" #--debug
}

run_jmeter() {
  local port="$1"
  local host="$2"
  local thread_count="$3"
  local loop_count="$4"
  local result_dir="$TEST_ROOT_DIRECTORY/result"
  local result_report_dir="$result_dir/result_report"
  local jmx_file="$TEST_ROOT_DIRECTORY/endpoints.jmx"
  local jtl_path="$result_dir/report.jtl"

  echo "=== Running JMeter Performance Tests ==="
  echo "  Host: $host:$port"
  echo "  Threads: $thread_count"
  echo "  Loops: $loop_count"
  echo ""

  jmeter \
        --nongui \
        --testfile "$jmx_file" \
        --logfile "$jtl_path" \
        --reportatendofloadtests \
        --reportoutputfolder "$result_report_dir" \
        --jmeterproperty "backend.port=$port" \
        --jmeterproperty "backend.host=$host" \
        --jmeterproperty "thread.count=$thread_count" \
        --jmeterproperty "loop.count=$loop_count" \
        --jmeterproperty "performance.data.directory=$result_dir" \
        --jmeterproperty "summary.report.path=$result_dir/result.xml"
}

check_thresholds() {
    local result_dir="$TEST_ROOT_DIRECTORY/result"
    local jtl_path="$result_dir/report.jtl"
    
    if [ ! -f "$jtl_path" ]; then
        echo "WARNING: JMeter result file not found at $jtl_path"
        return 0
    fi
    
    echo ""
    echo "=== Smoke Test Threshold Check ==="
    echo "  Max average response time threshold: ${SMOKE_THRESHOLD_TIME}ms"
    echo "  Min success rate threshold: ${SMOKE_THRESHOLD_SUCCESS}%"
    echo ""
    
    local total_samples=$(wc -l < "$jtl_path" | tr -d ' ')
    local success_samples=$(grep -c ",true," "$jtl_path" || echo "0")
    local failed_samples=$((total_samples - success_samples))
    
    if [ "$total_samples" -eq 0 ]; then
        echo "WARNING: No samples found in JMeter result"
        return 0
    fi
    
    local success_rate=$((success_samples * 100 / total_samples))
    echo "  Total samples: $total_samples"
    echo "  Successful: $success_samples"
    echo "  Failed: $failed_samples"
    echo "  Success rate: ${success_rate}%"
    
    local avg_time=$(awk -F',' '{sum+=$2; count++} END {if(count>0) printf "%d", sum/count; else print 0}' "$jtl_path")
    echo "  Average response time: ${avg_time}ms"
    echo ""
    
    local thresholds_passed=true
    
    if [ "$avg_time" -gt "$SMOKE_THRESHOLD_TIME" ]; then
        echo "  FAIL: Average response time (${avg_time}ms) exceeds threshold (${SMOKE_THRESHOLD_TIME}ms)"
        thresholds_passed=false
    else
        echo "  PASS: Average response time (${avg_time}ms) within threshold (${SMOKE_THRESHOLD_TIME}ms)"
    fi
    
    if [ "$success_rate" -lt "$SMOKE_THRESHOLD_SUCCESS" ]; then
        echo "  FAIL: Success rate (${success_rate}%) below threshold (${SMOKE_THRESHOLD_SUCCESS}%)"
        thresholds_passed=false
    else
        echo "  PASS: Success rate (${success_rate}%) meets threshold (${SMOKE_THRESHOLD_SUCCESS}%)"
    fi
    
    echo ""
    
    if [ "$thresholds_passed" = true ]; then
        echo "  RESULT: All thresholds PASSED"
        return 0
    else
        echo "  RESULT: Thresholds FAILED"
        if [ "$FAIL_ON_THRESHOLD" = true ]; then
            echo "  Failing test due to threshold violation"
            return 1
        else
            echo "  WARNING: --no-fail-on-threshold set, not failing test"
            return 0
        fi
    fi
}

cleanup
generate_db "$POSTGRESQL_PORT" "$POSTGRESQL_HOST" "$POSTGRESQL_USER" "$POSTGRESQL_PASSWORD" "$POSTGRESQL_DATABASE" "$DATABASE_SIZE"
run_jmeter "$POSTGREST_PORT" "$POSTGREST_HOST" "$TEST_THREAD_COUNT" "$TEST_LOOP_COUNT"

if [ "$SMOKE_MODE" = true ]; then
    check_thresholds
fi

#!/usr/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_PATH="${SCRIPT_DIR}/common-healthcheck-lib.sh"

if [[ -f "$LIB_PATH" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_PATH"
else
    HC_OK=0
    HC_ERROR_GENERAL=1
    HC_ERROR_CONFIG=2
    HC_ERROR_TIMEOUT=3
    HC_ERROR_DATABASE=4
    HC_ERROR_NOT_READY=5
    HC_ERROR_DEPENDENCY=6

    hc_log_error() { echo "[ERROR] $*"; }
    hc_log_info() { echo "[INFO] $*"; }
    hc_log_warn() { echo "[WARN] $*"; }
    hc_cleanup() { trap - SIGINT SIGTERM; kill -- -$$ 2>/dev/null || true; }
    hc_setup_trap() { trap 'hc_cleanup' SIGINT SIGTERM; }
fi

hc_setup_trap

HC_TIMEOUT="${HC_TIMEOUT:-5}"

POSTGRES_USER="${POSTGRES_USER:-haf_admin}"
POSTGRES_DB="${POSTGRES_DB:-haf_block_log}"

RESULT=$(timeout "$HC_TIMEOUT" psql -U "$POSTGRES_USER" --dbname "$POSTGRES_DB" --quiet --tuples-only --command="SELECT 1;" 2>&1) || {
    exit_code=$?
    if [ "$exit_code" = 124 ]; then
        hc_log_error "Database connection timed out after ${HC_TIMEOUT}s"
        exit $HC_ERROR_TIMEOUT
    else
        hc_log_error "Database connection failed: $RESULT"
        exit $HC_ERROR_DATABASE
    fi
}

if [[ "$RESULT" == *"1"* ]]; then
    hc_log_info "Database connection OK"
    exit $HC_OK
fi

hc_log_error "Unexpected database response"
exit $HC_ERROR_DATABASE

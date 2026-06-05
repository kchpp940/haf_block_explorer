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

HC_TIMEOUT="${HC_TIMEOUT:-10}"

INSTANCE_READY=$(timeout "$HC_TIMEOUT" psql -U haf_admin --dbname "haf_block_log" --quiet --tuples-only --command="SELECT hive.is_instance_ready()::VARCHAR;" 2>&1) || {
    hc_log_error "HAF health check failed - unable to query hive.is_instance_ready()"
    exit $HC_ERROR_DATABASE
}

if [[ "$INSTANCE_READY" == " true" ]]; then
    hc_log_info "HAF instance ready!"
    exit $HC_OK
else
    hc_log_warn "HAF instance still starting up."
    exit $HC_ERROR_NOT_READY
fi

#!/usr/bin/bash
set -euo pipefail

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
fi

hc_setup_trap

POSTGRES_USER="${POSTGRES_USER:-haf_admin}"
POSTGRES_DB="${POSTGRES_DB:-haf_block_log}"
HC_TIMEOUT="${HC_TIMEOUT:-10}"

INSTANCE_READY=""
ERROR_MSG=""

check_haf_ready() {
    local result
    result=$(timeout "$HC_TIMEOUT" psql -U "$POSTGRES_USER" --dbname "$POSTGRES_DB" --quiet --tuples-only --command="SELECT hive.is_instance_ready()::VARCHAR;" 2>&1) || {
        local exit_code=$?
        if [ "$exit_code" = 124 ]; then
            ERROR_MSG="HAF health check timed out after ${HC_TIMEOUT}s"
            return $HC_ERROR_TIMEOUT
        else
            ERROR_MSG="Database query failed: $result"
            return $HC_ERROR_DATABASE
        fi
    }
    
    INSTANCE_READY=$(echo "$result" | xargs)
    
    if [[ "$INSTANCE_READY" == "true" ]]; then
        return $HC_OK
    elif [[ "$INSTANCE_READY" == "false" ]]; then
        ERROR_MSG="HAF instance is still initializing or replaying"
        return $HC_ERROR_NOT_READY
    else
        ERROR_MSG="Unexpected response from hive.is_instance_ready(): '$INSTANCE_READY'"
        return $HC_ERROR_DATABASE
    fi
}

get_haf_status() {
    local result
    result=$(timeout "$HC_TIMEOUT" psql -U "$POSTGRES_USER" --dbname "$POSTGRES_DB" --quiet --tuples-only --command="
        SELECT 
            'head_block=' || COALESCE(head_block_num::text, 'N/A') || 
            ',irreversible=' || COALESCE(irreversible_block_num::text, 'N/A') ||
            ',is_replay=' || COALESCE(is_replaying::text, 'N/A')
        FROM hive.contexts WHERE name = 'hive';
    " 2>&1) || true
    echo "$result" | xargs
}

get_haf_progress() {
    local result
    result=$(timeout "$HC_TIMEOUT" psql -U "$POSTGRES_USER" --dbname "$POSTGRES_DB" --quiet --tuples-only --command="
        SELECT 
            CASE 
                WHEN is_replaying THEN 
                    'Replay in progress: ' || head_block_num || ' blocks'
                ELSE 
                    'Instance ready at block: ' || COALESCE(head_block_num::text, 'N/A')
            END
        FROM hive.contexts WHERE name = 'hive';
    " 2>&1) || true
    echo "$result" | xargs
}

main() {
    if ! command -v psql &> /dev/null; then
        hc_log_error "psql command not found - PostgreSQL client is required"
        return $HC_ERROR_GENERAL
    fi

    local status
    check_haf_ready || status=$?
    
    case "$status" in
        "$HC_OK")
            hc_log_info "HAF instance ready! Status: $(get_haf_status)"
            return $HC_OK
            ;;
        "$HC_ERROR_NOT_READY")
            hc_log_warn "$ERROR_MSG - $(get_haf_progress)"
            return $HC_ERROR_NOT_READY
            ;;
        "$HC_ERROR_TIMEOUT")
            hc_log_error "$ERROR_MSG"
            return $HC_ERROR_TIMEOUT
            ;;
        "$HC_ERROR_DATABASE")
            hc_log_error "$ERROR_MSG"
            return $HC_ERROR_DATABASE
            ;;
        *)
            hc_log_error "Health check failed with unknown status: $status"
            return "${status:-$HC_ERROR_GENERAL}"
            ;;
    esac
}

main || exit_code=$?
exit "${exit_code:-0}"

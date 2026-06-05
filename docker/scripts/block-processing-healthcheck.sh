#!/bin/bash
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
    hc_setup_trap() { trap 'hc_cleanup' SIGINT SIGTERM; }
fi

hc_setup_trap

postgres_user=${POSTGRES_USER:-"haf_admin"}
postgres_host=${POSTGRES_HOST:-"localhost"}
postgres_port=${POSTGRES_PORT:-5432}
postgres_db=${POSTGRES_DB:-"haf_block_log"}
HC_TIMEOUT=${HC_TIMEOUT:-10}

APP_CONTEXTS="${1:-hafbe_app,hafbe_bal}"
STARTUP_FILE="/tmp/block_processing_startup_time.txt"

export LC_ALL=C

build_postgres_url() {
    echo "postgresql://${postgres_user}@${postgres_host}:${postgres_port}/${postgres_db}?application_name=block_explorer_health_check"
}

get_context_status() {
    local pg_url
    pg_url=$(build_postgres_url)
    local contexts="$1"
    
    timeout "$HC_TIMEOUT" psql "$pg_url" --quiet --tuples-only --command="
        SELECT string_agg(name || '=(' || 
               'head=' || COALESCE(head_block_num::text, 'N/A') || 
               ',active=' || CASE WHEN last_active_at > now() - interval '1 minute' THEN 'yes' ELSE 'no' END || 
               ',in_sync=' || COALESCE(is_in_sync::text, 'no') || ')', '; ')
        FROM hafd.contexts 
        WHERE name IN (SELECT unnest(string_to_array('${contexts}', ',')));
    " 2>&1 || echo "query_failed"
}

check_startup_file() {
    if [[ ! -f "$STARTUP_FILE" ]]; then
        hc_log_warn "Startup file $STARTUP_FILE does not exist - block processing not started yet"
        return $HC_ERROR_NOT_READY
    fi
    
    local startup_time
    startup_time=$(cat "$STARTUP_FILE")
    if [[ -z "$startup_time" ]]; then
        hc_log_warn "Startup file $STARTUP_FILE is empty"
        return $HC_ERROR_NOT_READY
    fi
    
    return $HC_OK
}

check_block_processing() {
    local pg_url
    pg_url=$(build_postgres_url)
    local contexts="$1"
    
    local CHECK="
        SET TIME ZONE 'UTC';
        SELECT (
            (now() - (SELECT min(last_active_at) FROM hafd.contexts WHERE name IN (SELECT unnest(string_to_array('${contexts}', ',')))) < interval '1 minute')
            AND
            (SELECT min(last_active_at) FROM hafd.contexts WHERE name IN (SELECT unnest(string_to_array('${contexts}', ',')))) > '$(cat "$STARTUP_FILE")'::timestamp
        ) OR hive.is_app_in_sync(ARRAY(SELECT unnest(string_to_array('${contexts}', ','))));
    "
    
    local result
    result=$(timeout "$HC_TIMEOUT" psql "$pg_url" --quiet --no-align --tuples-only --command="${CHECK}" 2>&1) || {
        local exit_code=$?
        if [ "$exit_code" = 124 ]; then
            hc_log_error "Block processing health check timed out after ${HC_TIMEOUT}s"
            return $HC_ERROR_TIMEOUT
        else
            hc_log_error "Database query failed: $result"
            return $HC_ERROR_DATABASE
        fi
    }
    
    if [[ "$result" == "t" ]]; then
        return $HC_OK
    elif [[ "$result" == "f" ]]; then
        return $HC_ERROR_NOT_READY
    else
        hc_log_error "Unexpected query result: '$result'"
        return $HC_ERROR_DATABASE
    fi
}

main() {
    if ! command -v psql &> /dev/null; then
        hc_log_error "psql command not found - PostgreSQL client is required"
        return $HC_ERROR_GENERAL
    fi

    check_startup_file || return $?

    local status
    check_block_processing "$APP_CONTEXTS" || status=$?
    
    local context_status
    context_status=$(get_context_status "$APP_CONTEXTS")
    
    case "$status" in
        "$HC_OK")
            hc_log_info "Block processing healthy! Contexts: $context_status"
            return $HC_OK
            ;;
        "$HC_ERROR_NOT_READY")
            hc_log_warn "Block processing not ready yet. Contexts: $context_status"
            hc_log_warn "Waiting for sync or recent block processing activity"
            return $HC_ERROR_NOT_READY
            ;;
        *)
            hc_log_error "Block processing check failed. Contexts: $context_status"
            return "${status:-$HC_ERROR_GENERAL}"
            ;;
    esac
}

main || exit_code=$?
exit "${exit_code:-0}"

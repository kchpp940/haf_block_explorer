#!/bin/bash

set -euo pipefail

# Unified exit codes for health checks
export HC_OK=0
export HC_ERROR_GENERAL=1
export HC_ERROR_CONFIG=2
export HC_ERROR_TIMEOUT=3
export HC_ERROR_DATABASE=4
export HC_ERROR_NOT_READY=5
export HC_ERROR_DEPENDENCY=6

# Default timeout for health check operations (seconds)
HC_TIMEOUT=${HC_TIMEOUT:-10}

# Color codes for output
HC_RED='\033[0;31m'
HC_GREEN='\033[0;32m'
HC_YELLOW='\033[1;33m'
HC_NC='\033[0m'

hc_log_info() {
    echo -e "${HC_GREEN}[INFO]${HC_NC} $*"
}

hc_log_warn() {
    echo -e "${HC_YELLOW}[WARN]${HC_NC} $*"
}

hc_log_error() {
    echo -e "${HC_RED}[ERROR]${HC_NC} $*"
}

hc_cleanup() {
    trap - SIGINT SIGTERM
    kill -- -$$ 2>/dev/null || true
}

hc_setup_trap() {
    trap 'hc_cleanup' SIGINT SIGTERM
}

hc_validate_postgres_env() {
    local required_vars=("POSTGRES_USER" "POSTGRES_HOST" "POSTGRES_PORT")
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            hc_log_error "Required environment variable $var is not set"
            exit $HC_ERROR_CONFIG
        fi
    done

    if ! [[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGRES_PORT" -lt 1 ] || [ "$POSTGRES_PORT" -gt 65535 ]; then
        hc_log_error "POSTGRES_PORT must be a valid port number (1-65535), got: $POSTGRES_PORT"
        exit $HC_ERROR_CONFIG
    fi
}

hc_build_postgres_url() {
    local user="${1:-$POSTGRES_USER}"
    local host="${2:-$POSTGRES_HOST}"
    local port="${3:-$POSTGRES_PORT}"
    local db="${4:-haf_block_log}"
    local app_name="${5:-health_check}"
    
    echo "postgresql://${user}@${host}:${port}/${db}?application_name=${app_name}"
}

hc_check_postgres_connection() {
    local pg_url="${1:-$POSTGRES_ACCESS}"
    local timeout="${2:-$HC_TIMEOUT}"
    
    if ! command -v psql &> /dev/null; then
        hc_log_error "psql command not found"
        return $HC_ERROR_GENERAL
    fi

    local result
    result=$(timeout "$timeout" psql "$pg_url" --quiet --tuples-only --command="SELECT 1;" 2>&1) || {
        local exit_code=$?
        if [ "$exit_code" = 124 ]; then
            hc_log_error "Database connection timed out after ${timeout}s"
            return $HC_ERROR_TIMEOUT
        else
            hc_log_error "Database connection failed: $result"
            return $HC_ERROR_DATABASE
        fi
    }
    
    if [[ "$result" == *"1"* ]]; then
        return $HC_OK
    fi
    
    hc_log_error "Unexpected response from database"
    return $HC_ERROR_DATABASE
}

hc_check_schema_exists() {
    local pg_url="${1:-$POSTGRES_ACCESS}"
    local schema_name="$2"
    local timeout="${3:-$HC_TIMEOUT}"

    local result
    result=$(timeout "$timeout" psql "$pg_url" --quiet --tuples-only --command="SELECT EXISTS(SELECT 1 FROM information_schema.schemata WHERE schema_name = '${schema_name}');" 2>&1) || {
        hc_log_error "Failed to check schema '${schema_name}'"
        return $HC_ERROR_DATABASE
    }
    
    if [[ "$result" == *"t"* ]]; then
        return $HC_OK
    fi
    
    hc_log_warn "Schema '${schema_name}' does not exist yet"
    return $HC_ERROR_NOT_READY
}

hc_check_port_open() {
    local host="$1"
    local port="$2"
    local timeout="${3:-2}"
    
    if command -v nc &> /dev/null; then
        if nc -z -w "$timeout" "$host" "$port" 2>/dev/null; then
            return $HC_OK
        fi
    elif command -v bash &> /dev/null; then
        if (echo > /dev/tcp/"$host"/"$port") 2>/dev/null; then
            return $HC_OK
        fi
    fi
    
    return $HC_ERROR_NOT_READY
}

export -f hc_log_info hc_log_warn hc_log_error hc_cleanup hc_setup_trap
export -f hc_validate_postgres_env hc_build_postgres_url
export -f hc_check_postgres_connection hc_check_schema_exists hc_check_port_open

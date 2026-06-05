#! /bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[ENTRYPOINT]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[ENTRYPOINT WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ENTRYPOINT ERROR]${NC} $*"
}

log_config() {
    echo -e "${BLUE}[CONFIG]${NC} $*"
}

validate_env_vars() {
    local exit_code=0
    
    log_info "Validating environment configuration..."
    
    POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
    POSTGRES_PORT="${POSTGRES_PORT:-5432}"
    BTRACKER_SCHEMA="${BTRACKER_SCHEMA:-hafbe_bal}"
    POSTGREST_PORT="${POSTGREST_PORT:-3000}"
    POSTGREST_ADMIN_PORT="${POSTGREST_ADMIN_PORT:-3001}"
    
    log_config "POSTGRES_HOST=${POSTGRES_HOST}"
    log_config "POSTGRES_PORT=${POSTGRES_PORT}"
    log_config "BTRACKER_SCHEMA=${BTRACKER_SCHEMA}"
    log_config "POSTGREST_PORT=${POSTGREST_PORT}"
    log_config "POSTGREST_ADMIN_PORT=${POSTGREST_ADMIN_PORT}"
    
    if ! [[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGRES_PORT" -lt 1 ] || [ "$POSTGRES_PORT" -gt 65535 ]; then
        log_error "POSTGRES_PORT must be a valid port number (1-65535), got: $POSTGRES_PORT"
        exit_code=1
    fi
    
    if ! [[ "$POSTGREST_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGREST_PORT" -lt 1 ] || [ "$POSTGREST_PORT" -gt 65535 ]; then
        log_error "POSTGREST_PORT must be a valid port number (1-65535), got: $POSTGREST_PORT"
        exit_code=1
    fi
    
    if ! [[ "$POSTGREST_ADMIN_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGREST_ADMIN_PORT" -lt 1 ] || [ "$POSTGREST_ADMIN_PORT" -gt 65535 ]; then
        log_error "POSTGREST_ADMIN_PORT must be a valid port number (1-65535), got: $POSTGREST_ADMIN_PORT"
        exit_code=1
    fi
    
    if [[ "$POSTGREST_PORT" == "$POSTGREST_ADMIN_PORT" ]]; then
        log_error "POSTGREST_PORT and POSTGREST_ADMIN_PORT must be different"
        exit_code=1
    fi
    
    if [ -z "${BTRACKER_SCHEMA}" ]; then
        log_error "BTRACKER_SCHEMA cannot be empty"
        exit_code=1
    fi
    
    if ! [[ "$BTRACKER_SCHEMA" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "BTRACKER_SCHEMA contains invalid characters: $BTRACKER_SCHEMA"
        log_error "Schema name must start with a letter or underscore and contain only alphanumeric characters and underscores"
        exit_code=1
    fi
    
    if [ $exit_code -ne 0 ]; then
        log_error "Environment validation failed. Please fix the errors above and try again."
        exit 2
    fi
    
    log_info "Environment configuration validated successfully"
}

wait_for_postgres() {
    local max_attempts=30
    local attempt=1
    local wait_seconds=2
    
    log_info "Waiting for PostgreSQL at ${POSTGRES_HOST}:${POSTGRES_PORT}..."
    
    while [ $attempt -le $max_attempts ]; do
        if command -v pg_isready &> /dev/null; then
            if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "${POSTGRES_USER:-haf_admin}" -d postgres 2>/dev/null; then
                log_info "PostgreSQL is ready after $((attempt * wait_seconds)) seconds"
                return 0
            fi
        else
            if (echo > /dev/tcp/"$POSTGRES_HOST"/"$POSTGRES_PORT") 2>/dev/null; then
                log_info "PostgreSQL port is open after $((attempt * wait_seconds)) seconds"
                return 0
            fi
        fi
        
        log_warn "PostgreSQL not ready yet (attempt $attempt/$max_attempts)..."
        sleep $wait_seconds
        attempt=$((attempt + 1))
    done
    
    log_error "Timed out waiting for PostgreSQL after $((max_attempts * wait_seconds)) seconds"
    log_error "Please check:"
    log_error "  1. HAF container is running and healthy"
    log_error "  2. POSTGRES_HOST and POSTGRES_PORT are correct"
    log_error "  3. Network connectivity between containers"
    exit 3
}

validate_command() {
    local cmd="$1"
    
    case "$cmd" in
        install_app|process_blocks|uninstall_app)
            return 0
            ;;
        *)
            log_error "Unknown command: $cmd"
            echo ""
            echo "Usage: $0 {install_app|process_blocks|uninstall_app} [options]"
            echo ""
            echo "Commands:"
            echo "  install_app    - Install HAF Block Explorer application"
            echo "  process_blocks - Start block processing"
            echo "  uninstall_app  - Uninstall HAF Block Explorer application"
            exit 1
            ;;
    esac
}

cd /home/hived/haf_block_explorer/scripts

if [ $# -lt 1 ]; then
    log_error "No command specified"
    echo ""
    echo "Usage: $0 {install_app|process_blocks|uninstall_app} [options]"
    exit 1
fi

COMMAND="$1"
shift

validate_command "$COMMAND"
validate_env_vars

case "$COMMAND" in
    install_app)
        wait_for_postgres
        log_info "Executing install_app..."
        exec ./install_app.sh --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT}" --only-hafbe "$@"
        ;;
    process_blocks)
        wait_for_postgres
        log_info "Executing process_blocks..."
        exec ./process_blocks.sh --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT}" --user="${POSTGRES_USER:-hafbe_owner}" "$@"
        ;;
    uninstall_app)
        wait_for_postgres
        log_info "Executing uninstall_app..."
        exec ./uninstall_app.sh --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT}" --user="${POSTGRES_USER:-haf_admin}" "$@"
        ;;
esac

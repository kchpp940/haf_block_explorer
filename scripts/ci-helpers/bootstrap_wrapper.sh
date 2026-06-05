#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Bootstrap wrapper for CI jobs - starts HAFBE environment and waits for readiness.

OPTIONS:
    --backend-version=VERSION   HAF BE version (default: latest)
    --haf-data-directory=PATH   HAF Data directory path (default: /srv/haf/data)
    --haf-shm-directory=PATH    HAF SHM directory path (default: /srv/haf/shm)
    --setup-uid=UID             UID that HAF setup should be run as (default: 999)
    --logs-dir=DIR              Logs directory (default: ./logs/bootstrap)
    --compose-options=OPTS      Additional Docker Compose options
    --help|-h                   Display this help screen and exit
EOF
}

BACKEND_VERSION="latest"
HAF_DATA_DIRECTORY="/srv/haf/data"
HAF_SHM_DIRECTORY="/srv/haf/shm"
SETUP_UID="999"
LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/bootstrap"
COMPOSE_OPTIONS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --backend-version=*) BACKEND_VERSION="${1#*=}" ;;
        --haf-data-directory=*) HAF_DATA_DIRECTORY="${1#*=}" ;;
        --haf-shm-directory=*) HAF_SHM_DIRECTORY="${1#*=}" ;;
        --setup-uid=*) SETUP_UID="${1#*=}" ;;
        --logs-dir=*) LOGS_DIR="${1#*=}" ;;
        --compose-options=*) COMPOSE_OPTIONS="${1#*=}" ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
    esac
    shift
done

mkdir -p "${LOGS_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOGS_DIR}/bootstrap.log"
}

log_step() {
    echo "" | tee -a "${LOGS_DIR}/bootstrap.log"
    echo "=== $1 ===" | tee -a "${LOGS_DIR}/bootstrap.log"
}

log_step "Bootstrap Starting"
log "Backend version: ${BACKEND_VERSION}"
log "HAF data directory: ${HAF_DATA_DIRECTORY}"
log "HAF SHM directory: ${HAF_SHM_DIRECTORY}"
log "Setup UID: ${SETUP_UID}"
log "Logs directory: ${LOGS_DIR}"
log "Compose options: ${COMPOSE_OPTIONS}"

log_step "Creating environment file"
cat > "${PROJECT_ROOT}/docker/ci.env" <<EOF
BACKEND_VERSION=${BACKEND_VERSION}
BACKEND_REGISTRY=${CI_REGISTRY_IMAGE:-registry.gitlab.syncad.com/hive/haf_block_explorer}
HAF_DATA_DIRECTORY=${HAF_DATA_DIRECTORY}
HAF_SHM_DIRECTORY=${HAF_SHM_DIRECTORY}
HAF_REGISTRY=${HAF_REGISTRY:-registry.gitlab.syncad.com/hive/haf}
HAF_VERSION=${HAF_VERSION:-9ec94375}
HAFAH_REGISTRY=${HAFAH_REGISTRY:-registry.gitlab.syncad.com/hive/hafah}
HAFAH_VERSION=${HAFAH_VERSION:-latest}
SETUP_UID=${SETUP_UID}
POSTGREST_REGISTRY=${POSTGREST_REGISTRY:-postgrest/postgrest}
POSTGREST_VERSION=${POSTGREST_VERSION:-latest}
EOF
log "Environment file created at ${PROJECT_ROOT}/docker/ci.env"

log_step "Starting Docker Compose environment"
cd "${PROJECT_ROOT}/docker"
if [ -n "${COMPOSE_OPTIONS}" ]; then
    COMPOSE_OPTIONS_STRING="${COMPOSE_OPTIONS}" \
        "${SCRIPT_DIR}/start-ci-test-environment.sh" \
        --backend-version="${BACKEND_VERSION}" \
        --haf-data-directory="${HAF_DATA_DIRECTORY}" \
        --haf-shm-directory="${HAF_SHM_DIRECTORY}" \
        --setup-uid="${SETUP_UID}" 2>&1 | tee "${LOGS_DIR}/startup.log"
else
    COMPOSE_OPTIONS_STRING="--env-file ci.env --file docker-compose.yml --file overrides/ci.yml" \
        "${SCRIPT_DIR}/start-ci-test-environment.sh" \
        --backend-version="${BACKEND_VERSION}" \
        --haf-data-directory="${HAF_DATA_DIRECTORY}" \
        --haf-shm-directory="${HAF_SHM_DIRECTORY}" \
        --setup-uid="${SETUP_UID}" 2>&1 | tee "${LOGS_DIR}/startup.log"
fi

log_step "Waiting for HAFBE to be ready"
"${SCRIPT_DIR}/wait-for-haf-be-startup.sh" \
    --postgres-access="postgresql://haf_admin@localhost:5432/haf_block_log" 2>&1 | tee "${LOGS_DIR}/wait-for-ready.log"

log_step "Environment diagnostics"
{
    echo "--- Docker containers ---"
    docker compose --env-file ci.env --file docker-compose.yml --file overrides/ci.yml ps -a 2>&1 || true
    echo ""
    echo "--- HAF contexts ---"
    psql "postgresql://haf_admin@localhost:5432/haf_block_log" -c \
        "SELECT name, current_block_num, is_attached, state FROM hafd.contexts ORDER BY name;" 2>&1 || true
    echo ""
    echo "--- HAFBE schemas ---"
    psql "postgresql://haf_admin@localhost:5432/haf_block_log" -c \
        "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'haf%' ORDER BY nspname;" 2>&1 || true
} | tee "${LOGS_DIR}/diagnostics.log"

log_step "Bootstrap Complete"
log "HAFBE environment is ready"
log "All logs saved to: ${LOGS_DIR}"

echo "BOOTSTRAP_SUCCESS=true" > "${LOGS_DIR}/bootstrap.env"
echo "POSTGRES_ACCESS=postgresql://haf_admin@localhost:5432/haf_block_log" >> "${LOGS_DIR}/bootstrap.env"
echo "POSTGREST_URL=http://localhost:3000" >> "${LOGS_DIR}/bootstrap.env"

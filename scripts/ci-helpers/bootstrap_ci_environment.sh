#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOGS_DIR="${CI_LOGS_DIR:-${PROJECT_ROOT}/logs}/bootstrap"
ARTIFACTS_DIR="${CI_ARTIFACTS_DIR:-${PROJECT_ROOT}/artifacts}"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Bootstraps CI test environment with Docker Compose.

OPTIONS:
    --backend-version=VERSION   HAF BE version (default: latest)
    --haf-data-directory=PATH   HAF Data directory path (default: /srv/haf/data)
    --haf-shm-directory=PATH    HAF SHM directory path (default: /srv/haf/shm)
    --setup-uid=UID             UID that HAF setup should be run as (default: 999)
    --help|-h                   Display this help screen and exit
EOF
}

BACKEND_VERSION="latest"
HAF_DATA_DIRECTORY="/srv/haf/data"
HAF_SHM_DIRECTORY="/srv/haf/shm"
SETUP_UID="999"

while [ $# -gt 0 ]; do
    case "$1" in
        --backend-version=*) BACKEND_VERSION="${1#*=}" ;;
        --haf-data-directory=*) HAF_DATA_DIRECTORY="${1#*=}" ;;
        --haf-shm-directory=*) HAF_SHM_DIRECTORY="${1#*=}" ;;
        --setup-uid=*) SETUP_UID="${1#*=}" ;;
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

collect_container_logs() {
    log "Collecting container logs..."
    cd "${PROJECT_ROOT}/docker"
    for svc in $(docker compose --file docker-compose.yml --file overrides/ci.yml ps -a --format '{{.Service}}' 2>/dev/null); do
        docker compose --file docker-compose.yml --file overrides/ci.yml logs --no-log-prefix "$svc" > "${LOGS_DIR}/${svc}.log" 2>&1 || true
    done
}

trap 'collect_container_logs' EXIT

log_step "Configuration"
log "Backend version: ${BACKEND_VERSION}"
log "HAF data directory: ${HAF_DATA_DIRECTORY}"
log "HAF SHM directory: ${HAF_SHM_DIRECTORY}"
log "Setup UID: ${SETUP_UID}"

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
log "Environment file created"

log_step "Validating Docker Compose configuration"
cd "${PROJECT_ROOT}/docker"
docker compose --env-file ci.env --file docker-compose.yml --file overrides/ci.yml config \
    > "${LOGS_DIR}/docker-compose-config.yml" 2>&1
log "Configuration validated"

log_step "Starting Docker Compose services"
if ! timeout -s INT -k 5m 30m docker compose \
    --env-file ci.env \
    --file docker-compose.yml \
    --file overrides/ci.yml \
    up --detach --quiet-pull 2>&1 | tee -a "${LOGS_DIR}/docker-compose.log"; then
    log "ERROR: Docker Compose startup failed"
    exit 1
fi

log_step "Waiting for HAF to be healthy"
cd "${PROJECT_ROOT}/docker"
for i in {1..60}; do
    if docker compose --env-file ci.env --file docker-compose.yml --file overrides/ci.yml \
        exec -T haf pg_isready -U haf_admin -d haf_block_log >/dev/null 2>&1; then
        log "HAF is healthy"
        break
    fi
    if [ "$i" -eq 60 ]; then
        log "ERROR: HAF did not become healthy in time"
        exit 1
    fi
    sleep 10
done

log_step "Waiting for app-setup to complete"
cd "${PROJECT_ROOT}/docker"
for i in {1..120}; do
    STATUS=$(docker compose --env-file ci.env --file docker-compose.yml --file overrides/ci.yml \
        ps --format '{{.Status}}' app-setup 2>/dev/null || echo "")
    if echo "$STATUS" | grep -q "Exited (0)"; then
        log "app-setup completed successfully"
        break
    elif echo "$STATUS" | grep -q "Exited"; then
        log "ERROR: app-setup failed"
        docker compose --env-file ci.env --file docker-compose.yml --file overrides/ci.yml \
            logs app-setup 2>&1 | tee -a "${LOGS_DIR}/app-setup.log"
        exit 1
    fi
    if [ "$i" -eq 120 ]; then
        log "ERROR: app-setup did not complete in time"
        exit 1
    fi
    sleep 5
done

log_step "Waiting for block processing to be ready"
cd "${PROJECT_ROOT}"
POSTGRES_ACCESS="postgresql://haf_admin@localhost:5432/haf_block_log"
for i in {1..120}; do
    if psql "$POSTGRES_ACCESS" -qtAc "SELECT 1 FROM pg_namespace WHERE nspname='hafbe_app'" | grep -q 1; then
        log "HAFBE schema installed"
        break
    fi
    if [ "$i" -eq 120 ]; then
        log "ERROR: HAFBE schema not found"
        exit 1
    fi
    sleep 5
done

log_step "Environment bootstrap complete"
echo "BOOTSTRAP_SUCCESS=true" > "${ARTIFACTS_DIR}/bootstrap.env"
echo "POSTGRES_ACCESS=postgresql://haf_admin@localhost:5432/haf_block_log" >> "${ARTIFACTS_DIR}/bootstrap.env"
echo "POSTGREST_URL=http://localhost:3000" >> "${ARTIFACTS_DIR}/bootstrap.env"

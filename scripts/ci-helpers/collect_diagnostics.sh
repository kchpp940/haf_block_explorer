#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Collects diagnostics information for CI failure debugging.

OPTIONS:
    --stage=STAGE            CI stage name (build, bootstrap, sql-check, api-regression, performance-smoke)
    --output-dir=DIR         Output directory for diagnostics (default: ./diagnostics/\$STAGE)
    --postgres-access=URL    PostgreSQL connection URL (optional)
    --postgrest-url=URL      PostgREST URL (optional)
    --all                    Collect all diagnostics regardless of stage
    --help|-h                Display this help screen and exit
EOF
}

STAGE=""
OUTPUT_DIR=""
POSTGRES_ACCESS=""
POSTGREST_URL=""
COLLECT_ALL=false

while [ $# -gt 0 ]; do
    case "$1" in
        --stage=*) STAGE="${1#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${1#*=}" ;;
        --postgres-access=*) POSTGRES_ACCESS="${1#*=}" ;;
        --postgrest-url=*) POSTGREST_URL="${1#*=}" ;;
        --all) COLLECT_ALL=true ;;
        --help|-h) print_help; exit 0 ;;
        *) echo "ERROR: '$1' is not a valid option"; print_help; exit 2 ;;
    esac
    shift
done

if [ -z "$STAGE" ] && [ "$COLLECT_ALL" = false ]; then
    echo "ERROR: --stage or --all is required"
    print_help
    exit 2
fi

if [ -z "$OUTPUT_DIR" ] && [ -n "$STAGE" ]; then
    OUTPUT_DIR="${CI_DIAGNOSTICS_DIR:-${PROJECT_ROOT}/diagnostics}/${STAGE}"
elif [ -z "$OUTPUT_DIR" ] && [ "$COLLECT_ALL" = true ]; then
    OUTPUT_DIR="${CI_DIAGNOSTICS_DIR:-${PROJECT_ROOT}/diagnostics}/all"
fi

mkdir -p "${OUTPUT_DIR}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${OUTPUT_DIR}/diagnostics.log"
}

log_section() {
    echo "" | tee -a "${OUTPUT_DIR}/diagnostics.log"
    echo "=== $1 ===" | tee -a "${OUTPUT_DIR}/diagnostics.log"
}

log_section "Collecting Diagnostics"
log "Stage: ${STAGE:-all}"
log "Output Directory: ${OUTPUT_DIR}"
log "Timestamp: $(date -Iseconds)"

# System info
log_section "System Information"
{
    echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
    echo "OS: $(uname -a 2>/dev/null || echo unknown)"
    echo "Uptime: $(uptime 2>/dev/null || echo unknown)"
    echo "Disk Usage:"
    df -h 2>/dev/null || echo "unavailable"
    echo ""
    echo "Memory Usage:"
    free -h 2>/dev/null || vm_stat 2>/dev/null || echo "unavailable"
} | tee -a "${OUTPUT_DIR}/system-info.txt"
cp "${OUTPUT_DIR}/system-info.txt" "${OUTPUT_DIR}/diagnostics.log" 2>/dev/null || true

# Docker diagnostics (if available)
if command -v docker &> /dev/null; then
    log_section "Docker Diagnostics"
    
    {
        echo "--- Docker Version ---"
        docker version 2>&1 || echo "unavailable"
        echo ""
        echo "--- Docker System Info ---"
        docker system info 2>&1 || echo "unavailable"
        echo ""
        echo "--- Running Containers ---"
        docker ps -a 2>&1 || echo "unavailable"
        echo ""
        echo "--- Docker Images ---"
        docker images --digests 2>&1 || echo "unavailable"
        echo ""
        echo "--- Docker Volumes ---"
        docker volume ls 2>&1 || echo "unavailable"
        echo ""
        echo "--- Docker Networks ---"
        docker network ls 2>&1 || echo "unavailable"
    } > "${OUTPUT_DIR}/docker-info.txt"
    cat "${OUTPUT_DIR}/docker-info.txt" >> "${OUTPUT_DIR}/diagnostics.log"
    
    # Container logs
    if [ -f "${PROJECT_ROOT}/docker/docker-compose.yml" ]; then
        log "Collecting container logs..."
        cd "${PROJECT_ROOT}/docker"
        mkdir -p "${OUTPUT_DIR}/container-logs"
        
        for svc in $(docker compose ps -a --format '{{.Service}}' 2>/dev/null || true); do
            log "  Collecting logs for: $svc"
            docker compose logs --no-log-prefix --tail=1000 "$svc" \
                > "${OUTPUT_DIR}/container-logs/${svc}.log" 2>&1 || true
        done
        
        if [ "$(ls -A "${OUTPUT_DIR}/container-logs/" 2>/dev/null)" ]; then
            log "Container logs saved to: ${OUTPUT_DIR}/container-logs/"
        fi
    fi
fi

# PostgreSQL diagnostics
if [ -n "$POSTGRES_ACCESS" ] && command -v psql &> /dev/null; then
    log_section "PostgreSQL Diagnostics"
    
    {
        echo "--- PostgreSQL Version ---"
        psql "$POSTGRES_ACCESS" -c "SELECT version();" 2>&1 || echo "unavailable"
        echo ""
        echo "--- Database List ---"
        psql "$POSTGRES_ACCESS" -c "\\l" 2>&1 || echo "unavailable"
        echo ""
        echo "--- HAF Schemas ---"
        psql "$POSTGRES_ACCESS" -c "SELECT nspname FROM pg_namespace WHERE nspname LIKE 'haf%' ORDER BY nspname;" 2>&1 || echo "unavailable"
        echo ""
        echo "--- HAF Contexts ---"
        psql "$POSTGRES_ACCESS" -c "
            SELECT 
                name,
                current_block_num,
                irreversible_block,
                is_attached,
                state,
                last_active_at
            FROM hafd.contexts 
            ORDER BY name;
        " 2>&1 || echo "unavailable"
        echo ""
        echo "--- Active Connections ---"
        psql "$POSTGRES_ACCESS" -c "
            SELECT 
                pid,
                usename,
                application_name,
                state,
                now()-query_start as query_duration,
                LEFT(query, 100) as query
            FROM pg_stat_activity 
            WHERE state != 'idle'
            ORDER BY query_start DESC;
        " 2>&1 || echo "unavailable"
        echo ""
        echo "--- Lock Information ---"
        psql "$POSTGRES_ACCESS" -c "
            SELECT 
                pid,
                mode,
                granted,
                relation::regclass as relation
            FROM pg_locks 
            WHERE NOT granted;
        " 2>&1 || echo "unavailable"
    } > "${OUTPUT_DIR}/postgres-info.txt"
    cat "${OUTPUT_DIR}/postgres-info.txt" >> "${OUTPUT_DIR}/diagnostics.log"
fi

# PostgREST diagnostics
if [ -n "$POSTGREST_URL" ] && command -v curl &> /dev/null; then
    log_section "PostgREST Diagnostics"
    
    {
        echo "--- PostgREST Health Check ---"
        curl -s -v "${POSTGREST_URL}/" 2>&1 | head -50 || echo "unavailable"
        echo ""
        echo "--- PostgREST Ready Endpoint ---"
        curl -s "${POSTGREST_URL}:3001/ready" 2>&1 || echo "unavailable"
    } > "${OUTPUT_DIR}/postgrest-info.txt"
    cat "${OUTPUT_DIR}/postgrest-info.txt" >> "${OUTPUT_DIR}/diagnostics.log"
fi

# Environment variables
log_section "Environment Variables (relevant to CI)"
{
    env | grep -E "^(CI_|GITLAB_|HAF_|POSTGRES|DOCKER|BUILD_|REGISTRY)" | sort
} > "${OUTPUT_DIR}/environment.txt" 2>&1 || true
cat "${OUTPUT_DIR}/environment.txt" >> "${OUTPUT_DIR}/diagnostics.log" 2>/dev/null || true

# Git info
log_section "Git Information"
{
    echo "Commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    echo "Author: $(git log -1 --format='%an <%ae>' 2>/dev/null || echo unknown)"
    echo "Message: $(git log -1 --format='%s' 2>/dev/null || echo unknown)"
} > "${OUTPUT_DIR}/git-info.txt" 2>&1 || true
cat "${OUTPUT_DIR}/git-info.txt" >> "${OUTPUT_DIR}/diagnostics.log" 2>/dev/null || true

# Summary
log_section "Diagnostics Summary"
log "Diagnostics collected in: ${OUTPUT_DIR}"
log "Files generated:"
find "${OUTPUT_DIR}" -type f -name "*.txt" -o -name "*.log" | sort | while read -r file; do
    size=$(du -h "$file" | cut -f1)
    log "  - ${file#${OUTPUT_DIR}/} ($size)"
done

echo ""
echo "Diagnostics complete. Archive ${OUTPUT_DIR} for debugging."

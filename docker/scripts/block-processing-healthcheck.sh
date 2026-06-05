#! /bin/sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_PATH="${SCRIPT_DIR}/common-healthcheck-lib.sh"

if [ -f "$LIB_PATH" ]; then
    # shellcheck source=/dev/null
    . "$LIB_PATH"
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
    hc_cleanup() { trap - 2 15; kill -- -$$ 2>/dev/null || true; }
    hc_setup_trap() { trap 'hc_cleanup' 2 15; }
fi

hc_setup_trap

HC_TIMEOUT="${HC_TIMEOUT:-10}"

postgres_user=${POSTGRES_USER:-"haf_admin"}
postgres_host=${POSTGRES_HOST:-"localhost"}
postgres_port=${POSTGRES_PORT:-5432}
POSTGRES_ACCESS=${POSTGRES_URL:-"postgresql://$postgres_user@$postgres_host:$postgres_port/haf_block_log?application_name=block_explorer_health_check"}

APP_CONTEXTS="${1:-hafbe_app,hafbe_bal}"

export LC_ALL=C

# this health check will return healthy if:
# - haf_block_explorer has processed a block in the last 60 seconds
#   (as long as it was also after the container started, we don't want
#    to report healthy immediately after a restart)
# or
# - haf_block_explorer's head block has caught up to haf's irreversible block
#   (so we don't mark haf_block_explorer as unhealthy if HAF stops getting blocks)
#
# This check needs to know when the block processing started, so the docker entrypoint
# must write this to a file like:
#   date --utc --iso-8601=seconds > /tmp/block_processing_startup_time.txt
if [ ! -f "/tmp/block_processing_startup_time.txt" ]; then
  hc_log_warn "file /tmp/block_processing_startup_time.txt does not exist, which means block processing hasn't started yet"
  exit $HC_ERROR_NOT_READY
fi
STARTUP_TIME="$(cat /tmp/block_processing_startup_time.txt)"
CHECK="SET TIME ZONE 'UTC'; \
       SELECT ((now() - (SELECT min(last_active_at) FROM hafd.contexts WHERE name in (SELECT unnest(string_to_array('${APP_CONTEXTS}', ',')))) < interval '1 minute') \
               AND (SELECT min(last_active_at) FROM hafd.contexts WHERE name in (SELECT unnest(string_to_array('${APP_CONTEXTS}', ',')))) > '${STARTUP_TIME}'::timestamp) OR \
              hive.is_app_in_sync(ARRAY(SELECT unnest(string_to_array('${APP_CONTEXTS}', ','))));"

RESULT=$(timeout "$HC_TIMEOUT" psql "$POSTGRES_ACCESS" --quiet --no-align --tuples-only --command="${CHECK}" 2>&1) || {
    hc_log_error "Block processing health check query failed"
    exit $HC_ERROR_DATABASE
}

if [ "$RESULT" = "t" ]; then
    hc_log_info "Block processing is healthy"
    exit $HC_OK
else
    hc_log_warn "Block processing not ready yet"
    exit $HC_ERROR_NOT_READY
fi

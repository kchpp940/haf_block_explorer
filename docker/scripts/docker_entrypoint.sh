#! /bin/bash
set -e
cd /home/hived/haf_block_explorer/scripts

validate_config() {
    local errors=0

    POSTGRES_HOST="${POSTGRES_HOST-localhost}"
    POSTGRES_PORT="${POSTGRES_PORT-5432}"
    POSTGRES_USER="${POSTGRES_USER-hafbe_owner}"
    BTRACKER_SCHEMA="${BTRACKER_SCHEMA-hafbe_bal}"
    POSTGREST_PORT="${POSTGREST_PORT-3000}"
    POSTGREST_ADMIN_PORT="${POSTGREST_ADMIN_PORT-3001}"

    POSTGRES_ACCESS="postgresql://${POSTGRES_USER}@${POSTGRES_HOST}:${POSTGRES_PORT}/haf_block_log?application_name=block_explorer_entrypoint"

    if [ -z "${POSTGRES_HOST+set}" ]; then
        :
    elif [ -z "$POSTGRES_HOST" ]; then
        echo "[ENTRYPOINT ERROR] POSTGRES_HOST is set but empty" >&2
        errors=$((errors + 1))
    fi

    if [ -z "${POSTGRES_PORT+set}" ]; then
        :
    elif ! [[ "$POSTGRES_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGRES_PORT" -lt 1 ] || [ "$POSTGRES_PORT" -gt 65535 ]; then
        echo "[ENTRYPOINT ERROR] POSTGRES_PORT must be a valid port number (1-65535), got: '$POSTGRES_PORT'" >&2
        errors=$((errors + 1))
    fi

    if [ -z "${POSTGRES_USER+set}" ]; then
        :
    elif [ -z "$POSTGRES_USER" ]; then
        echo "[ENTRYPOINT ERROR] POSTGRES_USER is set but empty" >&2
        errors=$((errors + 1))
    fi

    if [ -z "${POSTGREST_PORT+set}" ]; then
        :
    elif ! [[ "$POSTGREST_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGREST_PORT" -lt 1 ] || [ "$POSTGREST_PORT" -gt 65535 ]; then
        echo "[ENTRYPOINT ERROR] POSTGREST_PORT must be a valid port number (1-65535), got: '$POSTGREST_PORT'" >&2
        errors=$((errors + 1))
    fi

    if [ -z "${POSTGREST_ADMIN_PORT+set}" ]; then
        :
    elif ! [[ "$POSTGREST_ADMIN_PORT" =~ ^[0-9]+$ ]] || [ "$POSTGREST_ADMIN_PORT" -lt 1 ] || [ "$POSTGREST_ADMIN_PORT" -gt 65535 ]; then
        echo "[ENTRYPOINT ERROR] POSTGREST_ADMIN_PORT must be a valid port number (1-65535), got: '$POSTGREST_ADMIN_PORT'" >&2
        errors=$((errors + 1))
    fi

    if [ -n "${POSTGREST_PORT-}" ] && [ -n "${POSTGREST_ADMIN_PORT-}" ] && [ "$POSTGREST_PORT" = "$POSTGREST_ADMIN_PORT" ]; then
        echo "[ENTRYPOINT ERROR] POSTGREST_PORT and POSTGREST_ADMIN_PORT must be different" >&2
        errors=$((errors + 1))
    fi

    if [ -z "${BTRACKER_SCHEMA+set}" ]; then
        :
    elif [ -z "$BTRACKER_SCHEMA" ]; then
        echo "[ENTRYPOINT ERROR] BTRACKER_SCHEMA is set but empty" >&2
        errors=$((errors + 1))
    elif ! [[ "$BTRACKER_SCHEMA" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        echo "[ENTRYPOINT ERROR] BTRACKER_SCHEMA contains invalid characters: '$BTRACKER_SCHEMA'" >&2
        echo "[ENTRYPOINT ERROR] Schema name must start with a letter or underscore and contain only alphanumeric characters and underscores" >&2
        errors=$((errors + 1))
    fi

    if [ -n "${POSTGRES_ACCESS-}" ] && ! [[ "$POSTGRES_ACCESS" =~ ^postgresql://[^@]+@[^:]+:[0-9]+/[^?]+(\?.*)?$ ]]; then
        echo "[ENTRYPOINT ERROR] POSTGRES_ACCESS format invalid: '$POSTGRES_ACCESS'" >&2
        errors=$((errors + 1))
    fi

    if [ $errors -ne 0 ]; then
        echo "[ENTRYPOINT ERROR] Configuration validation failed with $errors error(s). Aborting." >&2
        exit 2
    fi

    echo "[ENTRYPOINT] Configuration validated:" >&2
    echo "[ENTRYPOINT]   POSTGRES_HOST=${POSTGRES_HOST}" >&2
    echo "[ENTRYPOINT]   POSTGRES_PORT=${POSTGRES_PORT}" >&2
    echo "[ENTRYPOINT]   POSTGRES_USER=${POSTGRES_USER}" >&2
    echo "[ENTRYPOINT]   POSTGRES_ACCESS=${POSTGRES_ACCESS}" >&2
    echo "[ENTRYPOINT]   BTRACKER_SCHEMA=${BTRACKER_SCHEMA}" >&2
    echo "[ENTRYPOINT]   POSTGREST_PORT=${POSTGREST_PORT}" >&2
    echo "[ENTRYPOINT]   POSTGREST_ADMIN_PORT=${POSTGREST_ADMIN_PORT}" >&2
}

validate_config

if [ "$1" = "install_app" ]; then
  shift
  exec ./install_app.sh --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT:-5432}" --only-hafbe "$@"
elif [ "$1" = "process_blocks" ]; then
  shift
  exec ./process_blocks.sh --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT:-5432}" --user="${POSTGRES_USER:-hafbe_owner}" "$@"
elif [ "$1" = "uninstall_app" ]; then
  shift
  exec ./uninstall_app.sh --host="${POSTGRES_HOST}" --port="${POSTGRES_PORT:-5432}" --user="${POSTGRES_USER:-haf_admin}" "$@"
else
  echo "usage: $0 install_app|process_blocks|uninstall_app"
  exit 1
fi

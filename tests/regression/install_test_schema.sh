#!/usr/bin/env bash
# =============================================================================
# HAF Block Explorer Regression Test Schema Installer
#   (thin wrapper around test_bootstrap.py)
# =============================================================================
#
# NOTE: The actual implementation now lives in scripts/test_bootstrap.py.
#       This script is kept for backward compatibility. It forwards to:
#
#           scripts/test_bootstrap.py regression-install --type=all
#
# For the full list of subcommands and options run:
#           scripts/test_bootstrap.py --help
#
# Original purpose:
#   Installs the regression test schema (hafbe_test) which provides
#   infrastructure for comparing HAF Block Explorer's computed values against
#   expected values from a hived node snapshot.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAFBE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$HAFBE_DIR/scripts/test_bootstrap.py"

if [ ! -x "$BOOTSTRAP" ]; then
    chmod +x "$BOOTSTRAP" 2>/dev/null || true
fi

POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-haf_admin}"
POSTGRES_URL="${POSTGRES_URL:-}"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installs the regression test schema for HAF Block Explorer.

(Backward-compatible wrapper around scripts/test_bootstrap.py regression-install)

OPTIONS:
    --host=HOSTNAME     PostgreSQL hostname (default: localhost)
    --port=NUMBER       PostgreSQL port (default: 5432)
    --user=USERNAME     PostgreSQL user (default: haf_admin)
    --url=URL           PostgreSQL URL (overrides host/port/user)
    --help              Show this help message
EOF
    echo
    echo "See also: $BOOTSTRAP --help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host=*)    POSTGRES_HOST="${1#*=}" ;;
        --port=*)    POSTGRES_PORT="${1#*=}" ;;
        --user=*)    POSTGRES_USER="${1#*=}" ;;
        --url=*)     POSTGRES_URL="${1#*=}" ;;
        --help|-h)   print_help; exit 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
    esac
    shift
done

echo "Installing regression test schema..."
echo "  (delegating to scripts/test_bootstrap.py)"
echo "  Host: $POSTGRES_HOST:$POSTGRES_PORT  User: $POSTGRES_USER"
echo

BOOTSTRAP_ARGS=(regression-install
    --host="$POSTGRES_HOST"
    --port="$POSTGRES_PORT"
    --user="$POSTGRES_USER"
    --type=all
)
if [ -n "$POSTGRES_URL" ]; then
    BOOTSTRAP_ARGS+=(--url="$POSTGRES_URL")
fi

exec python3 "$BOOTSTRAP" "${BOOTSTRAP_ARGS[@]}"

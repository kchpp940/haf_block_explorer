#!/usr/bin/env bash
# =============================================================================
# HAFBE Proposal Mock Data Installation  (thin wrapper around test_bootstrap.py)
# =============================================================================
#
# NOTE: The actual implementation now lives in scripts/test_bootstrap.py.
#       This script is kept for backward compatibility with the existing
#       docker-compose-mocks.yml fill-db-with-mock-data service and with
#       developer muscle memory. It simply forwards to:
#
#           scripts/test_bootstrap.py mock-install
#
# For the full list of subcommands (check, mock-*, regression-*) and options
# run:  scripts/test_bootstrap.py --help
#
# Original workflow preserved below for reference.
# -----------------------------------------------------------------------------
# WORKFLOW:
#   1. ./tests/mocks/install_mock_data.sh           # load fixtures
#   2. ./scripts/process_blocks.sh --stop-at-block=91000006
#                                                   # process mock range
#   3. ./scripts/verify_mock_data.sh                # assert final state
#
# Block range: 91000000+ (chosen to NOT collide with btracker's 90000000+).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAFBE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP="$HAFBE_DIR/scripts/test_bootstrap.py"

if [ ! -x "$BOOTSTRAP" ]; then
    chmod +x "$BOOTSTRAP" 2>/dev/null || true
fi

POSTGRES_USER="${POSTGRES_USER:-haf_admin}"
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_URL="${POSTGRES_URL:-}"

print_help() {
    sed -n '2,/^# =\+$/p' "$0" | sed 's/^# \?//'
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
        *) echo "ERROR: unknown arg: $1"; exit 2 ;;
    esac
    shift
done

echo "=============================================="
echo "HAFBE proposal mock data install"
echo "  (delegating to scripts/test_bootstrap.py)"
echo "  Host: $POSTGRES_HOST:$POSTGRES_PORT  User: $POSTGRES_USER"
echo "=============================================="
echo

# Build argument list for the Python bootstrap
BOOTSTRAP_ARGS=(mock-install
    --host="$POSTGRES_HOST"
    --port="$POSTGRES_PORT"
    --user="$POSTGRES_USER"
)
if [ -n "$POSTGRES_URL" ]; then
    BOOTSTRAP_ARGS+=(--url="$POSTGRES_URL")
fi

exec python3 "$BOOTSTRAP" "${BOOTSTRAP_ARGS[@]}"

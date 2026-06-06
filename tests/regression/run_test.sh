#!/usr/bin/env bash
# =============================================================================
# HAF Block Explorer Regression Test  (thin wrapper around test_bootstrap.py)
# =============================================================================
#
# NOTE: The actual implementation now lives in scripts/test_bootstrap.py.
#       This script is kept for backward compatibility with existing CI jobs
#       and developer muscle memory. It simply forwards to:
#
#           scripts/test_bootstrap.py regression-full
#
# For the full list of subcommands (check, mock-*, regression-*) and options
# run:  scripts/test_bootstrap.py --help
#
# Original purpose preserved below for reference.
# -----------------------------------------------------------------------------
# PURPOSE:
#   Compares HAF Block Explorer's computed account and witness data against
#   expected values from a hived node snapshot to detect regressions.
#
# PREREQUISITES:
#   - HAF Block Explorer schema must be installed and synced
#   - accounts_dump.json.gz and/or witnesses_dump.json.gz fixtures must exist
#
# EXIT CODES:
#   0 - All data matches
#   1 - One or more accounts/witnesses have discrepancies
#   2 - Invalid arguments / missing fixture
#   3 - Database connectivity error
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
HAFBE_SCHEMA="${HAFBE_SCHEMA:-hafbe_app}"
TEST_TYPE="${TEST_TYPE:-all}"

print_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Runs regression test comparing HAF Block Explorer values against expected snapshot.

(Backward-compatible wrapper around scripts/test_bootstrap.py regression-full)

OPTIONS:
    --host=HOSTNAME     PostgreSQL hostname (default: localhost)
    --port=NUMBER       PostgreSQL port (default: 5432)
    --user=USERNAME     PostgreSQL user (default: haf_admin)
    --schema=SCHEMA     HAF Block Explorer schema name (default: hafbe_app)
    --type=TYPE         Test type: account, witness, or all (default: all)
    --help              Show this help message
EOF
    echo
    echo "See also: $BOOTSTRAP --help"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --host=*)
            POSTGRES_HOST="${1#*=}"
            ;;
        --port=*)
            POSTGRES_PORT="${1#*=}"
            ;;
        --user=*)
            POSTGRES_USER="${1#*=}"
            ;;
        --schema=*)
            HAFBE_SCHEMA="${1#*=}"
            ;;
        --type=*)
            TEST_TYPE="${1#*=}"
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            print_help >&2
            exit 2
            ;;
    esac
    shift
done

echo "=============================================="
echo "HAF Block Explorer Regression Test"
echo "  (delegating to scripts/test_bootstrap.py)"
echo "=============================================="
echo "  Host: $POSTGRES_HOST:$POSTGRES_PORT"
echo "  User: $POSTGRES_USER"
echo "  Schema: $HAFBE_SCHEMA"
echo "  Test Type: $TEST_TYPE"
echo ""

# Install psycopg2 if needed (not in CI — same logic as original script)
if [[ -z "${CI:-}" ]]; then
    echo "Ensuring Python dependencies are available..."
    python3 -c "import psycopg2" 2>/dev/null || pip install psycopg2-binary --quiet
    echo ""
fi

exec python3 "$BOOTSTRAP" regression-full \
    --host="$POSTGRES_HOST" \
    --port="$POSTGRES_PORT" \
    --user="$POSTGRES_USER" \
    --schema="$HAFBE_SCHEMA" \
    --type="$TEST_TYPE"

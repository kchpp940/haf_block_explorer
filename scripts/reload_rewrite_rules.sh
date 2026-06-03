#!/bin/bash

set -e

SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"
HAFBE_DIR="$(dirname "$SCRIPTDIR")"

POSTGRES_ACCESS=${POSTGRES_ACCESS:-"postgresql:///haf_block_log"}
REWRITES_FILE="${HAFBE_DIR}/endpoints/rewrite_rules.conf"

if [[ ! -f "$REWRITES_FILE" ]]; then
    echo "ERROR: $REWRITES_FILE not found"
    exit 1
fi

echo "Loading rewrite rules from $REWRITES_FILE ..."
REWRITE_CONTENT=$(cat "$REWRITES_FILE")
ESCAPED_CONTENT=$(echo "$REWRITE_CONTENT" | sed "s/'/''/g")

psql "$POSTGRES_ACCESS" -v "ON_ERROR_STOP=on" -c \
    "SET ROLE hafbe_owner; SELECT hafbe_backend.load_rewrite_rules('$ESCAPED_CONTENT');"

echo "Done. Verify with:"
echo "  SELECT * FROM hafbe_endpoints.get_endpoints_consistency();"

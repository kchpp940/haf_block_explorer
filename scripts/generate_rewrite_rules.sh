#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAFBE_DIR="$SCRIPT_DIR/.."
ENDPOINTS_DIR="$HAFBE_DIR/endpoints"
OUTPUT_FILE="$ENDPOINTS_DIR/rewrite_rules.conf"

# shellcheck source=scripts/endpoints_manifest.sh
source "$SCRIPT_DIR/endpoints_manifest.sh"

if [[ ! -f "$ENDPOINTS_JSON" ]]; then
    echo "Error: Endpoints manifest not found at $ENDPOINTS_JSON"
    exit 1
fi

echo "Generating rewrite_rules.conf from endpoints.json..."

validate_manifest

get_rewrite_rules > "$OUTPUT_FILE"

echo "Successfully generated $OUTPUT_FILE"
echo "Generated $(grep -c '^rewrite' "$OUTPUT_FILE") rewrite rules"

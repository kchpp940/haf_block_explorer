#!/bin/bash

ENDPOINTS_MANIFEST_VERSION="1.0"

: "${ENDPOINTS_DIR:?ENDPOINTS_DIR must be set before sourcing endpoints_manifest.sh}"
ENDPOINTS_JSON="${ENDPOINTS_JSON:-$ENDPOINTS_DIR/endpoints.json}"

ensure_jq() {
    if ! command -v jq &> /dev/null; then
        echo "WARNING: jq not found, using Python fallback for JSON parsing" >&2
        return 1
    fi
    return 0
}

parse_manifest_python() {
    local field="$1"
    local sort_by="${2:-}"
    
    python3 - "$ENDPOINTS_JSON" "$field" "$sort_by" << 'PYEOF'
import json
import sys

json_file = sys.argv[1]
field = sys.argv[2]
sort_by = sys.argv[3] if len(sys.argv) > 3 else ""

with open(json_file, 'r') as f:
    data = json.load(f)

if field == "schema_files":
    for item in data.get("schema_files", []):
        print(item)
elif field == "endpoints_sql":
    endpoints = data.get("endpoints", [])
    if sort_by:
        endpoints = sorted(endpoints, key=lambda x: x.get(sort_by, 999))
    for ep in endpoints:
        print(ep.get("sql_file", ""))
elif field == "rewrite_rules":
    endpoints = data.get("endpoints", [])
    if sort_by:
        endpoints = sorted(endpoints, key=lambda x: x.get(sort_by, 999))
    for ep in endpoints:
        print(ep.get("rewrite_rule", ""))
        print(ep.get("rewrite_comment", ""))
        print("")
    for fr in data.get("fallback_rules", []):
        print(fr.get("rewrite_rule", ""))
        print(fr.get("rewrite_comment", ""))
        print("")
PYEOF
}

get_schema_files() {
    if ensure_jq; then
        jq -r '.schema_files[]' "$ENDPOINTS_JSON"
    else
        parse_manifest_python "schema_files"
    fi
}

get_endpoints_for_install() {
    if ensure_jq; then
        jq -r '.endpoints | sort_by(.install_priority) | .[].sql_file' "$ENDPOINTS_JSON"
    else
        parse_manifest_python "endpoints_sql" "install_priority"
    fi
}

get_endpoints_for_openapi() {
    if ensure_jq; then
        jq -r '.endpoints | sort_by(.openapi_priority) | .[].sql_file' "$ENDPOINTS_JSON"
    else
        parse_manifest_python "endpoints_sql" "openapi_priority"
    fi
}

get_rewrite_rules() {
    local total_count
    local count=0
    
    total_count=$(jq '[.endpoints[], .fallback_rules[]] | length' "$ENDPOINTS_JSON" 2>/dev/null || echo "23")

    while IFS=$'\t' read -r rewrite_rule rewrite_comment; do
        [[ -z "$rewrite_rule" ]] && continue
        count=$((count + 1))
        echo "$rewrite_rule"
        echo "$rewrite_comment"
        if [[ "$count" -lt "$total_count" ]]; then
            echo ""
        fi
    done < <(
        if ensure_jq; then
            jq -r '
                [.endpoints[] | {priority: .rewrite_priority, rule: .rewrite_rule, comment: .rewrite_comment}] 
                + [.fallback_rules[] | {priority: 999, rule: .rewrite_rule, comment: .rewrite_comment}]
                | sort_by(.priority)
                | .[]
                | [.rule, .comment]
                | @tsv
            ' "$ENDPOINTS_JSON"
        else
            parse_manifest_python "rewrite_rules" "rewrite_priority"
        fi
    )
}

validate_manifest() {
    local validate_script
    local script_dir

    if [[ -n "${SCRIPTDIR:-}" && -f "${SCRIPTDIR}/validate_manifest.py" ]]; then
        script_dir="${SCRIPTDIR}"
    elif [[ -f "$(dirname "${BASH_SOURCE[0]:-$0}")/validate_manifest.py" ]]; then
        script_dir="$( cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1; pwd -P )"
    elif [[ -f "./scripts/validate_manifest.py" ]]; then
        script_dir="$(pwd)/scripts"
    else
        script_dir="$( cd -- "$(dirname "$0")" >/dev/null 2>&1; pwd -P )"
    fi

    validate_script="${script_dir}/validate_manifest.py"

    if [[ ! -f "$validate_script" ]]; then
        echo "ERROR: Cannot find validate_manifest.py (looked in: ${script_dir})" >&2
        return 1
    fi

    if [[ ! -f "$ENDPOINTS_JSON" ]]; then
        echo "ERROR: Endpoints manifest not found at $ENDPOINTS_JSON" >&2
        return 1
    fi

    echo "Validating endpoints manifest..."

    python3 "$validate_script" "$ENDPOINTS_JSON" "$ENDPOINTS_DIR"
    return $?
}

#!/bin/bash

set -e
set -o pipefail

SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit 1; pwd -P )"
HAFBE_DIR="$SCRIPTDIR/.."
ENDPOINTS_DIR="$HAFBE_DIR/endpoints"

# shellcheck source=scripts/endpoints_manifest.sh
source "$SCRIPTDIR/endpoints_manifest.sh"

# Fetch process_openapi.py from common-ci-configuration if not available locally
COMMON_CI_REF="${COMMON_CI_REF:-develop}"
COMMON_CI_URL="${COMMON_CI_URL:-https://gitlab.syncad.com/hive/common-ci-configuration/-/raw/${COMMON_CI_REF}}"
PROCESS_OPENAPI="${SCRIPTDIR}/process_openapi.py"

if [[ ! -f "$PROCESS_OPENAPI" ]]; then
    echo "Fetching process_openapi.py from common-ci-configuration (ref: ${COMMON_CI_REF})..."
    curl -fsSL "${COMMON_CI_URL}/haf-app-tools/python/process_openapi.py" -o "$PROCESS_OPENAPI"
fi

if [[ ! -f "$ENDPOINTS_JSON" ]]; then
    echo "Error: Endpoints manifest not found at $ENDPOINTS_JSON"
    exit 1
fi

endpoints="endpoints"
rewrite_dir="${endpoints}_openapi"
input_file="rewrite_rules.conf"
temp_output_file=$(mktemp)

build_endpoints_in_order() {
    local result=""
    local endpoints_dir="../$endpoints"

    while IFS= read -r schema_file; do
        [[ -n "$schema_file" ]] || continue
        result+="$endpoints_dir/$schema_file"$'\n'
    done < <(get_schema_files)

    while IFS= read -r sql_file; do
        [[ -n "$sql_file" ]] || continue
        result+="$endpoints_dir/$sql_file"$'\n'
    done < <(get_endpoints_for_openapi)

    echo "$result"
}

OUTPUT="$SCRIPTDIR/output"
ENDPOINTS_IN_ORDER="$(build_endpoints_in_order)"

# Function to reverse the lines
reverse_lines() {
    awk '
    BEGIN {
        RS = ""
        FS = "\n"
    }
    {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^#/) {
                comment = $i
            } else if ($i ~ /^rewrite/) {
                rewrite = $i
            }
        }
        if (NR > 1) {
            print ""
        }
        print comment
        print rewrite
    }' "$input_file" | tac
}

# Function to install pip3
install_pip() {
    echo "pip3 is not installed. Installing now..."
    # Ensure Python 3 is installed
    if ! command -v python3 &> /dev/null; then
        echo "Python 3 is not installed. Please install Python 3 first."
        exit 1
    fi
    # Try to install pip3
    sudo apt-get update
    sudo apt-get install -y python3-pip
    if ! command -v pip3 &> /dev/null; then
        echo "pip3 installation failed. Please install pip3 manually."
        exit 1
    fi
}

# Check if pip3 is installed
if ! command -v pip3 &> /dev/null; then
    install_pip
fi

# Check if deepmerge is installed
if python3 -c "import deepmerge" &> /dev/null; then
    echo "deepmerge is already installed."
else
    echo "deepmerge is not installed. Installing now..."
    pip3 install deepmerge
    echo "deepmerge has been installed."
fi

# Check if jsonpointer is installed
if python3 -c "import jsonpointer" &> /dev/null; then
    echo "jsonpointer is already installed."
else
    echo "jsonpointer is not installed. Installing now..."
    pip3 install jsonpointer
    echo "jsonpointer has been installed."
fi

echo "Using endpoints directories"
echo "$ENDPOINTS_IN_ORDER"

validate_manifest

# Generate rewrite_rules.conf from endpoints manifest
"$SCRIPTDIR/generate_rewrite_rules.sh"

# run openapi rewrite script
# shellcheck disable=SC2086
python3 "$PROCESS_OPENAPI" $OUTPUT $ENDPOINTS_IN_ORDER

# Move rewritten directory to endpoints_openapi
rm -rf "$SCRIPTDIR/../$rewrite_dir"
mv "$OUTPUT/../$endpoints" "$SCRIPTDIR/../$rewrite_dir"
rm -rf "$SCRIPTDIR/output"

# Create rewrite_rules.conf inside endpoints_openapi
# Read from the generated file in endpoints/ directory
input_file="$HAFBE_DIR/endpoints/rewrite_rules.conf"
reverse_lines > "$temp_output_file"
mv "$temp_output_file" "$SCRIPTDIR/../$rewrite_dir/rewrite_rules.conf"
echo "Rewritten scripts saved in $rewrite_dir"

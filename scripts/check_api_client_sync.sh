#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
PROJECT_ROOT="$( cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 ; pwd -P )"

FIXTURES_DIR="${PROJECT_ROOT}/scripts/api_generation/fixtures"
OPENAPI_SPEC="${FIXTURES_DIR}/openapi_spec.json"
REWRITE_RULES="${FIXTURES_DIR}/rewrite_rules.conf"
CLIENT_DIR="${PROJECT_ROOT}/scripts/python_api_package/hiveio_hafbe_api/hafbe_api_client"

print_help() {
    cat <<'EOF'
Usage: ./scripts/check_api_client_sync.sh

CI entry point for verifying the generated Python API client is in sync with
the committed OpenAPI fixtures and rewrite rules. This script is invoked by
both the `setup-scripts-test` and `python_api_client_test` GitLab CI jobs.

The script performs the following steps in order:
  1. Pre-check that required fixture files exist
  2. Pre-check that the generated Python client directory contains .py files
  3. Run the lint/validation gate: ./scripts/ci-helpers/run_lint.sh openapi python

Exit codes:
  0  All checks passed — fixtures exist, client exists, and openapi+python
     lint gates are green (client matches the committed fixtures)
  2  Required fixture file(s) missing. Expected:
       - scripts/api_generation/fixtures/openapi_spec.json
       - scripts/api_generation/fixtures/rewrite_rules.conf
     Run: python scripts/api_generation/generate_and_validate.py export-fixtures
  3  Client regenerated from fixtures differs from the committed version.
     Run:  python scripts/api_generation/generate_and_validate.py sync-client
     then commit the regenerated files under scripts/python_api_package/hiveio_hafbe_api/hafbe_api_client/
  4  Generated Python client is missing (no .py files in
     scripts/python_api_package/hiveio_hafbe_api/hafbe_api_client/).
     Run: ./scripts/api_generation/generate_hafbe_api_client.sh
     or:  python scripts/api_generation/generate_and_validate.py sync-client

Examples:
  # Standard invocation — what CI runs
  ./scripts/check_api_client_sync.sh

  # Show this help
  ./scripts/check_api_client_sync.sh --help
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    print_help
    exit 0
fi

if [ "${1:-}" != "" ]; then
    echo "ERROR: unexpected argument '$1'"
    echo
    print_help
    exit 1
fi

if [ ! -f "${OPENAPI_SPEC}" ] || [ ! -f "${REWRITE_RULES}" ]; then
    echo "ERROR: required fixture file(s) missing."
    [ ! -f "${OPENAPI_SPEC}" ]    && echo "  missing: ${OPENAPI_SPEC}"
    [ ! -f "${REWRITE_RULES}" ]   && echo "  missing: ${REWRITE_RULES}"
    echo
    echo "Run the fixture exporter first:"
    echo "  python scripts/api_generation/generate_and_validate.py export-fixtures"
    exit 2
fi

if [ ! -d "${CLIENT_DIR}" ]; then
    echo "ERROR: generated Python client directory not found."
    echo "  expected: ${CLIENT_DIR}"
    echo
    echo "Generate the client first:"
    echo "  ./scripts/api_generation/generate_hafbe_api_client.sh"
    echo "  or: python scripts/api_generation/generate_and_validate.py sync-client"
    exit 4
fi

py_count=$(find "${CLIENT_DIR}" -maxdepth 1 -type f -name "*.py" | wc -l | tr -d ' ')
if [ "${py_count}" -eq 0 ]; then
    echo "ERROR: no .py files found in generated client directory."
    echo "  directory: ${CLIENT_DIR}"
    echo
    echo "Generate the client first:"
    echo "  ./scripts/api_generation/generate_hafbe_api_client.sh"
    echo "  or: python scripts/api_generation/generate_and_validate.py sync-client"
    exit 4
fi

cd "${PROJECT_ROOT}"

exec ./scripts/ci-helpers/run_lint.sh openapi python

#! /bin/bash
#
# Unified entry point for verifying the HAFBE Python API client is in sync
# with the SQL endpoint definitions. Runs ALL checks in strict mode; any
# failure aborts with a non-zero exit code and a clear remediation message.
#
# Intended for:
#   * GitLab CI `python_api_client_test` and `setup-scripts-test` jobs
#   * Local `./tests/functional/test_scripts.sh`
#   * Pre-commit hooks
#
# Exit codes:
#   0  all checks passed
#   2  fixtures out of date (endpoint_schema.sql / rewrite_rules.conf changed
#      without running `export-fixtures`)
#   3  generated client differs from what the fixed fixtures produce
#      (run `sync-client` and commit the changes)
#   4  generated client directory missing or empty
#   5  pytest-based endpoint sync tests failed

set -euo pipefail

SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
API_GEN_DIR="${SCRIPTDIR}/api_generation"
PYAPI_DIR="${SCRIPTDIR}/python_api_package"

echo "============================================================"
echo " HAFBE API Client Synchronisation Check"
echo "============================================================"
echo

echo "--- Step 1/2: generate_and_validate.py check-all ---"
poetry -C "${API_GEN_DIR}" run python "${API_GEN_DIR}/generate_and_validate.py" check-all
echo

echo "--- Step 2/2: python_api_package endpoint_sync tests ---"
poetry -C "${PYAPI_DIR}" run pytest "${PYAPI_DIR}/tests/test_endpoint_sync.py" -v
echo

echo "============================================================"
echo " ALL API CLIENT SYNC CHECKS PASSED"
echo "============================================================"

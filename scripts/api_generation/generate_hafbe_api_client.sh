#! /bin/bash

set -xeuo pipefail

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

BASE_DIR="${SCRIPTPATH}"
PACKAGE_DIR="${SCRIPTPATH}/../python_api_package"
SWAGGER_DIR="${BASE_DIR}/../../build"

if [[ "${USE_LEGACY_GENERATION:-0}" == "1" ]]; then
  poetry run -C "${BASE_DIR}" python "${BASE_DIR}/generate_hafbe_api_client.py" "${PACKAGE_DIR}" "${SWAGGER_DIR}"
else
  poetry run -C "${BASE_DIR}" python "${BASE_DIR}/generate_and_validate.py" sync-client
fi

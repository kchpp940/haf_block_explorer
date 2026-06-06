#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
PROJECT_ROOT="$( cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 ; pwd -P )"

print_help() {
cat <<'EOF'
Usage: ./scripts/ci-helpers/run_lint.sh [CHECK...]

Wrapper around ./scripts/check_project.sh --ci for use in upstream GitLab CI.
Runs the same lint and validation gates as a developer would run locally,
with machine-friendly output (no ANSI color, shellcheck=checkstyle XML,
pytest=JUnit XML) suitable for CI artifact collection.

CHECKS (optional, default: all):
  sql        SQLFluff SQL code style
  shell      ShellCheck shell script lint
  openapi    OpenAPI rewrite validation (pytest, scripts/api_generation/tests)
  python     Python package tests (pytest, scripts/python_api_package/tests)

Exit code:
  0  all selected checks passed
  1  one or more selected checks failed (same as CI job failure)

Examples:
  # Run all four lint gates (default, what the CI lint stage should do)
  ./scripts/ci-helpers/run_lint.sh

  # Run only shell + SQL lint
  ./scripts/ci-helpers/run_lint.sh shell sql

Artifacts written to project root (for CI artifact collection):
  shellcheck-checkstyle.xml     ShellCheck checkstyle XML (via --ci)
  openapi-tests.junit.xml       OpenAPI pytest JUnit XML   (via --ci)
  python-package-tests.junit.xml Python pytest JUnit XML   (via --ci)
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    print_help
    exit 0
fi

CHECK_ARGS=()

if [ $# -eq 0 ]; then
    CHECK_ARGS=(--all)
else
    for arg in "$@"; do
        case "$arg" in
            sql)     CHECK_ARGS+=(--sql) ;;
            shell)   CHECK_ARGS+=(--shell) ;;
            openapi) CHECK_ARGS+=(--openapi) ;;
            python)  CHECK_ARGS+=(--python) ;;
            *)
                echo "ERROR: unknown check name '$arg'"
                echo
                print_help
                exit 2
                ;;
        esac
    done
fi

cd "${PROJECT_ROOT}"

exec ./scripts/check_project.sh --ci "${CHECK_ARGS[@]}"
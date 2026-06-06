#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
PROJECT_ROOT="$( cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 ; pwd -P )"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0
FAILED_CHECKS=""

print_help() {
    cat <<'HELP_EOF'
Usage: ./scripts/check_project.sh [OPTION]...

Unified project quality checks replicating CI lint and validation gates.
Runs locally what CI runs: SQL lint, shell lint, OpenAPI rewrite validation,
and Python package tests.

OPTIONS:
  --sql         Run only SQLFluff SQL code style checks
  --shell       Run only ShellCheck shell script lint
  --openapi     Run only OpenAPI rewrite validation tests
  --python      Run only Python package tests
  --all         Run all checks (default behavior)
  --fix         Attempt auto-fix (currently: SQLFluff)
  --verbose     Show detailed output for each check
  --help, -h    Show this help message and exit
HELP_EOF
}

print_header() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  %s${NC}\n" "$1"
    printf "${CYAN}========================================${NC}\n"
}

print_pass() {
    printf "${GREEN}[PASS]${NC} %s\n" "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
}

print_fail() {
    printf "${RED}[FAIL]${NC} %s\n" "$1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    FAILED_CHECKS="${FAILED_CHECKS}
- $1"
}

print_skip() {
    printf "${YELLOW}[SKIP]${NC} %s\n" "$1"
    SKIP_COUNT=$((SKIP_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_python_module() {
    python3 -c "import $1" >/dev/null 2>&1
}

run_sqlfluff() {
    print_header "SQLFluff - SQL Code Style"

    if ! command_exists sqlfluff; then
        print_skip "sqlfluff not installed - skipping SQL lint"
        printf "  install via: pip install sqlfluff\n"
        return 0
    fi

    printf "Linting SQL files with sqlfluff...\n"

    local fix_flag="lint"
    if [ "${FIX_MODE}" = "true" ]; then
        fix_flag="fix"
        printf "  auto-fix mode enabled\n"
    fi

    local verbose_flag=""
    if [ "${VERBOSE}" = "true" ]; then
        verbose_flag="--verbose"
    fi

    local output_file="/tmp/check_project_sqlfluff_$$.log"
    local exit_code=0

    (
        cd "${PROJECT_ROOT}"
        sqlfluff ${fix_flag} ${verbose_flag} --config .sqlfluff
    ) > "${output_file}" 2>&1 || exit_code=$?

    if [ ${exit_code} -eq 0 ]; then
        print_pass "SQLFluff checks passed"
        if [ "${VERBOSE}" = "true" ]; then
            cat "${output_file}"
        fi
    else
        print_fail "SQLFluff found issues"
        cat "${output_file}"
    fi

    rm -f "${output_file}"
}

run_shellcheck() {
    print_header "ShellCheck - Shell Script Lint"

    if ! command_exists shellcheck; then
        print_skip "shellcheck not installed - skipping shell lint"
        printf "  install via: brew install shellcheck (macOS) or apt-get install shellcheck (Debian/Ubuntu)\n"
        return 0
    fi

    printf "Linting shell scripts...\n"

    local shell_scripts
    shell_scripts=$(find "${PROJECT_ROOT}" -type f -name "*.sh" \
        -not -path "*/node_modules/*" \
        -not -path "*/submodules/*" \
        -not -path "*/.git/*" \
        -print0 | tr '\0' '\n')

    local script_count
    script_count=$(printf "%s\n" "${shell_scripts}" | grep -c '.' || true)

    if [ "${script_count}" -eq 0 ]; then
        print_skip "No shell scripts found"
        return 0
    fi

    local shellcheck_format="gcc"
    if [ "${VERBOSE}" = "true" ]; then
        shellcheck_format="tty"
    fi

    local output_file="/tmp/check_project_shellcheck_$$.log"
    local exit_code=0

    # shellcheck disable=SC2086
    echo "${shell_scripts}" | xargs shellcheck \
        --shell=bash \
        --exclude=SC1090,SC1091,SC2059,SC2086,SC2155 \
        --format="${shellcheck_format}" \
        > "${output_file}" 2>&1 || exit_code=$?

    if [ ${exit_code} -eq 0 ]; then
        print_pass "ShellCheck passed for ${script_count} scripts"
    else
        print_fail "ShellCheck found issues"
        cat "${output_file}"
    fi

    rm -f "${output_file}"
}

run_openapi_validation() {
    print_header "OpenAPI Rewrite Validation"

    if ! command_exists python3; then
        print_skip "python3 not installed - skipping OpenAPI validation"
        return 0
    fi

    if ! check_python_module pytest; then
        print_skip "pytest not installed - skipping OpenAPI validation"
        printf "  install via: pip install pytest poetry\n"
        return 0
    fi

    printf "Validating OpenAPI rewrite rules and extraction...\n"

    local api_gen_dir="${PROJECT_ROOT}/scripts/api_generation"

    if [ ! -d "${api_gen_dir}/tests" ]; then
        print_skip "OpenAPI test directory not found"
        return 0
    fi

    local pytest_args="-v"
    if [ "${VERBOSE}" != "true" ]; then
        pytest_args="-q"
    fi

    local output_file="/tmp/check_project_openapi_$$.log"
    local exit_code=0

    (
        cd "${api_gen_dir}"
        if command_exists poetry && [ -f "pyproject.toml" ]; then
            printf "  using poetry environment\n"
            poetry run pytest ${pytest_args} tests/
        else
            printf "  using system python\n"
            python3 -m pytest ${pytest_args} tests/
        fi
    ) > "${output_file}" 2>&1 || exit_code=$?

    if [ ${exit_code} -eq 0 ]; then
        print_pass "OpenAPI rewrite validation passed"
        if [ "${VERBOSE}" = "true" ]; then
            cat "${output_file}"
        fi
    else
        print_fail "OpenAPI rewrite validation failed"
        cat "${output_file}"
    fi

    rm -f "${output_file}"
}

run_python_tests() {
    print_header "Python Package Tests"

    if ! command_exists python3; then
        print_skip "python3 not installed - skipping Python tests"
        return 0
    fi

    printf "Running Python package tests...\n"

    local pkg_dir="${PROJECT_ROOT}/scripts/python_api_package"

    if [ ! -d "${pkg_dir}/tests" ]; then
        print_skip "Python package test directory not found"
        return 0
    fi

    local pytest_args="-v"
    if [ "${VERBOSE}" != "true" ]; then
        pytest_args="-q"
    fi

    local output_file="/tmp/check_project_python_$$.log"
    local exit_code=0

    (
        cd "${pkg_dir}"
        if command_exists poetry && [ -f "pyproject.toml" ]; then
            printf "  using poetry environment\n"
            poetry run pytest ${pytest_args} tests/test_package_import.py tests/test_generated_api_client.py
        else
            printf "  using system python\n"
            python3 -m pytest ${pytest_args} tests/test_package_import.py tests/test_generated_api_client.py
        fi
    ) > "${output_file}" 2>&1 || exit_code=$?

    if [ ${exit_code} -eq 0 ]; then
        print_pass "Python package tests passed"
        if [ "${VERBOSE}" = "true" ]; then
            cat "${output_file}"
        fi
    else
        print_fail "Python package tests failed"
        cat "${output_file}"
    fi

    rm -f "${output_file}"
}

print_summary() {
    printf "\n"
    printf "${CYAN}========================================${NC}\n"
    printf "${CYAN}  CHECK SUMMARY${NC}\n"
    printf "${CYAN}========================================${NC}\n"
    printf "  Total:  %s\n" "${TOTAL_COUNT}"
    printf "  ${GREEN}Passed: %s${NC}\n" "${PASS_COUNT}"
    if [ "${FAIL_COUNT}" -gt 0 ]; then
        printf "  ${RED}Failed: %s${NC}\n" "${FAIL_COUNT}"
    fi
    if [ "${SKIP_COUNT}" -gt 0 ]; then
        printf "  ${YELLOW}Skipped: %s${NC}\n" "${SKIP_COUNT}"
    fi
    printf "\n"

    if [ "${FAIL_COUNT}" -gt 0 ]; then
        printf "${RED}Some checks FAILED:${NC}\n"
        printf "%s\n" "${FAILED_CHECKS}"
        printf "\n"
        printf "See above for details.\n"
        exit 1
    else
        printf "${GREEN}All checks passed or skipped.${NC}\n"
    fi
}

RUN_SQL=false
RUN_SHELL=false
RUN_OPENAPI=false
RUN_PYTHON=false
RUN_ALL=true
FIX_MODE=false
VERBOSE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --sql)
            RUN_SQL=true
            RUN_ALL=false
            ;;
        --shell)
            RUN_SHELL=true
            RUN_ALL=false
            ;;
        --openapi)
            RUN_OPENAPI=true
            RUN_ALL=false
            ;;
        --python)
            RUN_PYTHON=true
            RUN_ALL=false
            ;;
        --all)
            RUN_ALL=true
            ;;
        --fix)
            FIX_MODE=true
            ;;
        --verbose)
            VERBOSE=true
            ;;
        --help|-h|-\?)
            print_help
            exit 0
            ;;
        -*)
            printf "ERROR: '%s' is not a valid option\n" "$1"
            printf "\n"
            print_help
            exit 1
            ;;
        *)
            printf "ERROR: '%s' is not a valid argument\n" "$1"
            printf "\n"
            print_help
            exit 2
            ;;
    esac
    shift
done

printf "${CYAN}HAF Block Explorer - Project Quality Checks${NC}\n"
printf "Project root: %s\n" "${PROJECT_ROOT}"
printf "\n"

if [ "${RUN_ALL}" = "true" ] || [ "${RUN_SQL}" = "true" ]; then
    run_sqlfluff
fi

if [ "${RUN_ALL}" = "true" ] || [ "${RUN_SHELL}" = "true" ]; then
    run_shellcheck
fi

if [ "${RUN_ALL}" = "true" ] || [ "${RUN_OPENAPI}" = "true" ]; then
    run_openapi_validation
fi

if [ "${RUN_ALL}" = "true" ] || [ "${RUN_PYTHON}" = "true" ]; then
    run_python_tests
fi

print_summary

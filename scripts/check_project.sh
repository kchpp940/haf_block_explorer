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

disable_colors() {
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
}

ci_echo() {
    if [ "${CI_MODE}" = "true" ]; then
        printf "%s\n" "$1"
    fi
}

print_help() {
    cat <<'HELP_EOF'
Usage: ./scripts/check_project.sh [OPTION]...

Unified project quality checks replicating CI lint and validation gates.
Runs locally what CI runs: SQL lint, shell lint, OpenAPI rewrite validation,
and Python package tests.

By default the script runs in STRICT mode: if a required tool is missing,
that check FAILS (mirroring CI). Use --allow-missing-tools to gracefully skip
checks whose tools are not installed.

OPTIONS:
  --sql                  Run only SQLFluff SQL code style checks
  --shell                Run only ShellCheck shell script lint
  --openapi              Run only OpenAPI rewrite validation tests
  --python               Run only Python package tests
  --all                  Run all checks (default behavior)
  --fix                  Attempt auto-fix (currently: SQLFluff)
  --verbose              Show detailed output for each check
  --allow-missing-tools  Skip (instead of failing) checks whose required tools
                         are not installed locally
  --install-deps         Run ./scripts/setup_dependencies.sh --install-lint-tools
                         to install all tools required by this script, then exit
  --ci                   CI mode: machine-friendly output (no color,
                         shellcheck=checkstyle, pytest=junit XML). The exact
                         format upstream CI uses.
  --help, -h             Show this help message and exit
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

handle_missing_tool() {
    local tool_name="$1"
    local install_hint="$2"

    if [ "${ALLOW_MISSING_TOOLS}" = "true" ]; then
        print_skip "${tool_name} not installed - skipping"
        if [ -n "${install_hint}" ]; then
            printf "  install via: %s\n" "${install_hint}"
            printf "  or run: %s\n" "./scripts/check_project.sh --install-deps"
        fi
        return 0
    else
        print_fail "${tool_name} not installed (use --allow-missing-tools to skip)"
        if [ -n "${install_hint}" ]; then
            printf "  install via: %s\n" "${install_hint}"
            printf "  or run: %s\n" "./scripts/check_project.sh --install-deps"
        fi
        return 1
    fi
}

install_dependencies() {
    print_header "Installing lint and test dependencies"
    printf "Running: ./scripts/setup_dependencies.sh --install-lint-tools\n\n"
    exec "${SCRIPT_DIR}/setup_dependencies.sh" --install-lint-tools
}

run_sqlfluff() {
    print_header "SQLFluff - SQL Code Style"

    local sqlfluff_cmd=""
    if command_exists sqlfluff; then
        sqlfluff_cmd="sqlfluff"
    elif command_exists python3 && python3 -m sqlfluff --version >/dev/null 2>&1; then
        sqlfluff_cmd="python3 -m sqlfluff"
    fi

    if [ -z "${sqlfluff_cmd}" ]; then
        handle_missing_tool "sqlfluff" "pip install sqlfluff" || return 0
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
        # shellcheck disable=SC2086
        ${sqlfluff_cmd} ${fix_flag} ${verbose_flag} --config .sqlfluff
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
        handle_missing_tool "shellcheck" "brew install shellcheck (macOS) / apt-get install shellcheck (Debian/Ubuntu)" || return 0
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
    if [ "${CI_MODE}" = "true" ]; then
        shellcheck_format="checkstyle"
    elif [ "${VERBOSE}" = "true" ]; then
        shellcheck_format="tty"
    fi

    local output_file="/tmp/check_project_shellcheck_$$.log"
    local ci_artifact="${PROJECT_ROOT}/shellcheck-checkstyle.xml"
    local exit_code=0

    # shellcheck disable=SC2086
    echo "${shell_scripts}" | xargs shellcheck \
        --shell=bash \
        --exclude=SC1090,SC1091,SC2059,SC2086,SC2155 \
        --format="${shellcheck_format}" \
        > "${output_file}" 2>&1 || exit_code=$?

    if [ "${CI_MODE}" = "true" ]; then
        cp "${output_file}" "${ci_artifact}"
    fi

    if [ ${exit_code} -eq 0 ]; then
        print_pass "ShellCheck passed for ${script_count} scripts"
        if [ "${CI_MODE}" = "true" ]; then
            printf "  CI artifact: shellcheck-checkstyle.xml (checkstyle format for scripts/ci-helpers/checkstyle2junit.xslt)\n"
        fi
    else
        print_fail "ShellCheck found issues"
        if [ "${CI_MODE}" = "true" ]; then
            printf "  CI artifact saved to shellcheck-checkstyle.xml\n"
        fi
        cat "${output_file}"
    fi

    rm -f "${output_file}"
}

run_openapi_validation() {
    print_header "OpenAPI Rewrite Validation"

    if ! command_exists python3; then
        handle_missing_tool "python3" "install Python 3.12+" || return 0
        return 0
    fi

    if ! check_python_module pytest; then
        handle_missing_tool "pytest" "pip install pytest poetry" || return 0
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
    if [ "${CI_MODE}" = "true" ]; then
        pytest_args="${pytest_args} --junitxml=${PROJECT_ROOT}/openapi-tests.junit.xml"
    fi

    local output_file="/tmp/check_project_openapi_$$.log"
    local exit_code=0

    (
        cd "${api_gen_dir}"
        if command_exists poetry && [ -f "pyproject.toml" ]; then
            printf "  using poetry environment (same as CI)\n"
            poetry run pytest ${pytest_args} tests/
        else
            handle_missing_tool "poetry" "pip install poetry" || return 1
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
        handle_missing_tool "python3" "install Python 3.12+" || return 0
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
    if [ "${CI_MODE}" = "true" ]; then
        pytest_args="${pytest_args} --junitxml=${PROJECT_ROOT}/python-package-tests.junit.xml"
    fi

    local output_file="/tmp/check_project_python_$$.log"
    local exit_code=0

    (
        cd "${pkg_dir}"
        if command_exists poetry && [ -f "pyproject.toml" ]; then
            printf "  using poetry environment (same as CI)\n"
            poetry run pytest ${pytest_args} tests/test_package_import.py tests/test_endpoint_sync.py
        else
            handle_missing_tool "poetry" "pip install poetry" || return 1
            printf "  using system python\n"
            python3 -m pytest ${pytest_args} tests/test_package_import.py tests/test_endpoint_sync.py
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
    printf "  Mode:   "
    if [ "${ALLOW_MISSING_TOOLS}" = "true" ]; then
        printf "${YELLOW}permissive (missing tools skip)${NC}\n"
    else
        printf "${GREEN}strict (same as CI)${NC}\n"
    fi
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
        printf "To install missing tools: %s\n" "./scripts/check_project.sh --install-deps"
        printf "To allow skipping missing tools: %s\n" "./scripts/check_project.sh --allow-missing-tools"
        exit 1
    else
        if [ "${SKIP_COUNT}" -gt 0 ] && [ "${ALLOW_MISSING_TOOLS}" = "true" ]; then
            printf "${YELLOW}All remaining checks passed. %d check(s) skipped due to missing tools.${NC}\n" "${SKIP_COUNT}"
            printf "Install missing tools with: %s\n" "./scripts/check_project.sh --install-deps"
        else
            printf "${GREEN}All checks passed.${NC}\n"
        fi
    fi
}

RUN_SQL=false
RUN_SHELL=false
RUN_OPENAPI=false
RUN_PYTHON=false
RUN_ALL=true
FIX_MODE=false
VERBOSE=false
ALLOW_MISSING_TOOLS=false
CI_MODE=false

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
        --allow-missing-tools)
            ALLOW_MISSING_TOOLS=true
            ;;
        --install-deps)
            install_dependencies
            ;;
        --ci)
            CI_MODE=true
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

if [ "${CI_MODE}" = "true" ]; then
    disable_colors
fi

printf "${CYAN}HAF Block Explorer - Project Quality Checks${NC}\n"
printf "Project root: %s\n" "${PROJECT_ROOT}"
if [ "${ALLOW_MISSING_TOOLS}" = "true" ]; then
    printf "Mode:         %s\n" "permissive (missing tools skip)"
else
    printf "Mode:         %s\n" "strict (missing tools fail — same as CI)"
fi
if [ "${CI_MODE}" = "true" ]; then
    printf "Output:       machine-friendly (CI mode)\n"
fi
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

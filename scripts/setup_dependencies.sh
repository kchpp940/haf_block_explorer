#!/bin/bash

set -e
set -o pipefail

detect_os() {
	case "$(uname -s)" in
		Darwin) echo "macos" ;;
		Linux)  echo "linux" ;;
		*)      echo "unknown" ;;
	esac
}

install_utilities() {
	local os
	os="$(detect_os)"
	if [ "$os" = "macos" ]; then
		brew install git moreutils
	else
		sudo apt -y install git moreutils
	fi
}

install_postgrest() {
  local postgrest_v=$1

  local os
  os="$(detect_os)"
  if [ "$os" = "macos" ]; then
    brew install wget curl jq xz
  else
    sudo apt-get install -y wget curl jq xz-utils
  fi

  local postgrest_url
  postgrest_url="$(curl "https://api.github.com/repos/PostgREST/postgrest/releases/$postgrest_v" | jq -r '.assets[] | select (.name | contains("linux-static-x64")) | .browser_download_url')"
  local postgrest_archive="postgrest-linux-static-x64.tar.xz"
  wget "$postgrest_url" -O "$postgrest_archive"

  sudo tar xvf "$postgrest_archive" -C '/usr/local/bin'
  rm "$postgrest_archive"
}

install_python() {
  local os
  os="$(detect_os)"

  if [ "$os" = "macos" ]; then
    brew install python@3.12 python-tk
  else
    DEBIAN_FRONTEND=noninteractive sudo apt-get -y install python3 python3-pip python3-venv
  fi

  python3 -m venv .tests
  # shellcheck source=/dev/null
  source .tests/bin/activate
  pip install psycopg2-binary
  deactivate
}

install_jmeter() {
  local jmeter_v=$1

  local os
  os="$(detect_os)"
  if [ "$os" = "macos" ]; then
    brew install unzip openjdk wget
  else
    sudo apt-get install -y unzip openjdk-8-jdk wget
  fi

  wget "https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-${jmeter_v}.zip"

  jmeter_src="apache-jmeter-${jmeter_v}"
  sudo unzip "${jmeter_src}.zip" -d '/opt'
  rm "${jmeter_src}.zip"

  jmeter="jmeter-${jmeter_v}"
  cat <<EOF > "$jmeter"
#!/usr/bin/env bash

cd "/opt/apache-jmeter-${jmeter_v}/bin"
./jmeter \$@
EOF
  sudo chmod +x "$jmeter"
  sudo mv "$jmeter" "/usr/local/bin/${jmeter}"
  sudo ln -sf "/usr/local/bin/${jmeter}" "/usr/local/bin/jmeter"

  sudo chmod 777 "/opt/apache-jmeter-$jmeter_v/bin"
}

install_lint_tools() {
  local os
  os="$(detect_os)"
  SCRIPT_DIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
  PROJECT_ROOT="$( cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 ; pwd -P )"

  echo "[lint-tools] Detected OS: $os"

  # shellcheck
  echo "[lint-tools] Installing shellcheck..."
  if [ "$os" = "macos" ]; then
    if ! command -v shellcheck >/dev/null 2>&1; then
      brew install shellcheck
    fi
  else
    if ! command -v shellcheck >/dev/null 2>&1; then
      sudo apt-get install -y shellcheck
    fi
  fi

  # python3 + pip (prerequisite for sqlfluff and poetry)
  echo "[lint-tools] Ensuring python3 and pip are available..."
  if ! command -v python3 >/dev/null 2>&1; then
    if [ "$os" = "macos" ]; then
      brew install python@3.12
    else
      DEBIAN_FRONTEND=noninteractive sudo apt-get -y install python3 python3-pip python3-venv
    fi
  fi

  if ! python3 -m pip --version >/dev/null 2>&1; then
    if [ "$os" = "macos" ]; then
      python3 -m ensurepip --upgrade
    else
      DEBIAN_FRONTEND=noninteractive sudo apt-get -y install python3-pip
    fi
  fi

  # sqlfluff
  echo "[lint-tools] Installing sqlfluff..."
  if ! python3 -c "import sqlfluff" >/dev/null 2>&1; then
    python3 -m pip install --user sqlfluff
  fi

  # poetry
  echo "[lint-tools] Installing poetry..."
  if ! command -v poetry >/dev/null 2>&1; then
    python3 -m pip install --user poetry
  fi

  # python test deps (pytest etc.) via poetry in the two project packages
  echo "[lint-tools] Installing scripts/api_generation poetry environment..."
  (
    cd "${PROJECT_ROOT}/scripts/api_generation"
    poetry install
  )

  echo "[lint-tools] Installing scripts/python_api_package poetry environment..."
  (
    cd "${PROJECT_ROOT}/scripts/python_api_package"
    poetry install
  )

  echo "[lint-tools] All lint and test dependencies installed."
}

print_help () {
cat <<EOF
  Usage: $0 [OPTION[=VALUE]]...

  Installs dependencies for HAF Block Explorer development.
  OPTIONS:
    --install-all        Install all dependencies (utilities, postgrest, python, jmeter, lint-tools)
    --install-utilities  Install utilities (git, moreutils)
    --install-postgrest  Install PostgREST
    --install-python     Install Python 3 and psycopg2-binary
    --install-jmeter     Install JMeter
    --install-lint-tools Install lint and quality-check tools:
                         shellcheck, sqlfluff, poetry, and project poetry environments
                         (this is what ./scripts/check_project.sh needs)
EOF
}

postgrest_v="latest"
jmeter_v="5.4.3"

while [ $# -gt 0 ]; do
  case "$1" in
    --install-all)
        if [ "$(detect_os)" = "linux" ]; then
          sudo apt-get update
        fi
        install_utilities
        install_postgrest $postgrest_v
        install_python
        install_jmeter $jmeter_v
        install_lint_tools
        ;;
    --install-utilities)
        if [ "$(detect_os)" = "linux" ]; then
          sudo apt-get update
        fi
        install_utilities
        ;;
    --install-postgrest)
        if [ "$(detect_os)" = "linux" ]; then
          sudo apt-get update
        fi
        install_postgrest $postgrest_v
        ;;
    --install-python)
        if [ "$(detect_os)" = "linux" ]; then
          sudo apt-get update
        fi
        install_python
        ;;
    --install-jmeter)
        if [ "$(detect_os)" = "linux" ]; then
          sudo apt-get update
        fi
        install_jmeter $jmeter_v
        ;;
    --install-lint-tools)
        install_lint_tools
        ;;
    --help|-h|-\?)
        print_help
        exit 0
        ;;
    -*)
        echo "ERROR: '$1' is not a valid option"
        echo
        print_help
        exit 1
        ;;
    *)
        echo "ERROR: '$1' is not a valid argument"
        echo
        print_help
        exit 2
        ;;
    esac
    shift
done

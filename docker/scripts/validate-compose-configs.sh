#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_info() { echo "[INFO] $*"; }

cd "$DOCKER_DIR"

check_docker_available() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    if ! docker info &>/dev/null; then
        return 2
    fi
    return 0
}

declare -a COMBINATIONS=(
    "base|-f docker-compose.yml"
    "base+dev|-f docker-compose.yml -f overrides/dev.yml"
    "base+ci|-f docker-compose.yml -f overrides/ci.yml"
    "base+ci-mocks|-f docker-compose.yml -f overrides/ci-mocks.yml"
    "test standalone|-f docker-compose-test.yml"
    "mocks standalone|-f docker-compose-mocks.yml"
)

run_docker_compose_config() {
    local label="$1"
    local flags="$2"
    local output
    output=$(eval "docker compose $flags config -q" 2>&1) || {
        log_fail "$label"
        echo "$output" | sed 's/^/         /'
        return 1
    }
    log_ok "$label"
    return 0
}

run_python_fallback_validation() {
    python3 - "$DOCKER_DIR" <<'PYEOF'
import sys, os, copy, yaml

docker_dir = sys.argv[1]

EXPECTED_HAF_FULL_HC = {"interval": "60s", "timeout": "10s", "retries": 3, "start_period": "48h"}
EXPECTED_HAF_DB_HC   = {"interval": "10s", "timeout": "5s", "retries": 30, "start_period": "60s"}
EXPECTED_BLOCK_HC    = {"interval": "60s", "timeout": "5s", "retries": 20, "start_period": "72h"}

def load(p):
    with open(p) as f:
        d = yaml.safe_load(f)
    if not isinstance(d, dict):
        raise ValueError(f"{p}: not a YAML mapping")
    return d

def merge(base, override):
    result = copy.deepcopy(base)
    for k, v in override.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = merge(result[k], v)
        else:
            result[k] = copy.deepcopy(v)
    return result

def check(label, data, haf_hc_expected):
    errors = []
    svcs = data.get("services", {})
    if "haf" in svcs:
        svc = svcs["haf"]
        hc = svc.get("healthcheck")
        if not hc:
            errors.append("haf: missing healthcheck")
        else:
            test = hc.get("test")
            if not test:
                errors.append("haf: healthcheck missing test")
            elif "healthcheck.sh" not in " ".join(str(t) for t in test):
                errors.append(f"haf: unexpected healthcheck test: {test}")

            vols = svc.get("volumes", [])
            targets = [v.split(":")[1] if isinstance(v, str) and ":" in v else None for v in vols]
            if "/home/hived/common-healthcheck-lib.sh" not in targets:
                errors.append("haf: missing common-healthcheck-lib.sh mount")
            if "/home/hived/healthcheck.sh" not in targets:
                errors.append("haf: missing healthcheck.sh mount")

            for k, exp in haf_hc_expected.items():
                if hc.get(k) != exp:
                    errors.append(f"haf: healthcheck.{k}={hc.get(k)!r} expected {exp!r}")

    for name in ("backend-block-processing", "backend-rep-block-processing"):
        if name in svcs:
            svc = svcs[name]
            hc = svc.get("healthcheck")
            if not hc:
                errors.append(f"{name}: missing healthcheck")
            else:
                test = hc.get("test")
                if not test or "block-processing-healthcheck.sh" not in " ".join(str(t) for t in test):
                    errors.append(f"{name}: wrong healthcheck test")
                vols = svc.get("volumes", [])
                targets = [v.split(":")[1] if isinstance(v, str) and ":" in v else None for v in vols]
                if "/home/hived/haf_block_explorer/common-healthcheck-lib.sh" not in targets:
                    errors.append(f"{name}: missing lib mount")
                if "/home/hived/haf_block_explorer/block-processing-healthcheck.sh" not in targets:
                    errors.append(f"{name}: missing script mount")
                for k, exp in EXPECTED_BLOCK_HC.items():
                    if hc.get(k) != exp:
                        errors.append(f"{name}: healthcheck.{k}={hc.get(k)!r} expected {exp!r}")
    return errors

combinations = [
    ("base",             f"{docker_dir}/docker-compose.yml",        None,                            EXPECTED_HAF_FULL_HC),
    ("base+dev",         f"{docker_dir}/docker-compose.yml",        f"{docker_dir}/overrides/dev.yml",        EXPECTED_HAF_FULL_HC),
    ("base+ci",          f"{docker_dir}/docker-compose.yml",        f"{docker_dir}/overrides/ci.yml",         EXPECTED_HAF_FULL_HC),
    ("base+ci-mocks",    f"{docker_dir}/docker-compose.yml",        f"{docker_dir}/overrides/ci-mocks.yml",   EXPECTED_HAF_FULL_HC),
    ("test standalone",  f"{docker_dir}/docker-compose-test.yml",   None,                            EXPECTED_HAF_DB_HC),
    ("mocks standalone", f"{docker_dir}/docker-compose-mocks.yml",  None,                            EXPECTED_HAF_FULL_HC),
]

all_ok = True
for label, base_p, ovr_p, haf_hc_expected in combinations:
    try:
        base = load(base_p)
        data = merge(base, load(ovr_p)) if ovr_p else base
        errors = check(label, data, haf_hc_expected)
        if errors:
            all_ok = False
            print(f"[FAIL] {label}")
            for e in errors:
                print(f"       {e}")
        else:
            print(f"[OK]   {label}")
    except Exception as ex:
        all_ok = False
        print(f"[FAIL] {label}: {ex}")

sys.exit(0 if all_ok else 1)
PYEOF
}

echo "=== Docker Compose Configuration Validator ==="
echo ""

set +e
check_docker_available
docker_status=$?
set -e

if [ $docker_status -eq 0 ]; then
    log_info "Docker daemon is available. Running 'docker compose config -q'..."
    echo ""
    all_ok=0
    for combo in "${COMBINATIONS[@]}"; do
        label="${combo%%|*}"
        flags="${combo#*|}"
        run_docker_compose_config "$label" "$flags" || all_ok=1
    done
    echo ""
    if [ $all_ok -eq 0 ]; then
        log_ok "All configurations validated via Docker Compose"
    else
        log_fail "Some configurations failed Docker Compose validation"
        exit 1
    fi
elif [ $docker_status -eq 1 ]; then
    log_warn "'docker' binary not found in PATH. Skipping 'docker compose config -q'."
    log_warn "Falling back to Python-based YAML/merge validation..."
    echo ""
    if run_python_fallback_validation; then
        echo ""
        log_ok "All configurations validated via Python fallback"
    else
        echo ""
        log_fail "Some configurations failed validation"
        exit 1
    fi
else
    log_warn "Docker binary found but daemon is not running. Skipping 'docker compose config -q'."
    log_warn "Falling back to Python-based YAML/merge validation..."
    echo ""
    if run_python_fallback_validation; then
        echo ""
        log_ok "All configurations validated via Python fallback"
    else
        echo ""
        log_fail "Some configurations failed validation"
        exit 1
    fi
fi

echo ""
log_info "Tip: install and start Docker Desktop to enable 'docker compose config -q' validation."

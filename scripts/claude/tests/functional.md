# Functional Tests

## Purpose

Functional tests verify that HAFBE's install and uninstall scripts work correctly, and — most importantly — that the generated Python API client stays in sync with the SQL endpoint definitions. This ensures deployment scripts don't break between releases and that endpoint/client drift is caught as early as possible.

## How It Works

1. **API Client Sync check**: Runs `./scripts/check_api_client_sync.sh` — verifies fixtures, client existence, client content match, and pytest endpoint assertions. Runs first, requires no database.
2. **Reinstall test**: Runs `install_app.sh` on existing database
3. **Uninstall test**: Runs `uninstall_app.sh` to remove schema
4. **Validation**: Scripts exit with non-zero status on failure; `set -euo pipefail` aborts on the first error

## Running Tests

### Basic Execution
```bash
cd tests/functional
./test_scripts.sh --host=localhost
```

### Options
| Option | Description | Default |
|--------|-------------|---------|
| `--host=HOSTNAME` | PostgreSQL host | localhost |

## Test File Structure

```
tests/functional/
└── test_scripts.sh              # Main test runner
```

## What Gets Tested

### Test 1: API Client Synchronisation (Mandatory, No Database)
```bash
./scripts/check_api_client_sync.sh
```
Runs two steps:
1. `generate_and_validate.py check-all` — verifies OpenAPI/rewrite fixtures match SQL, generated client exists, and freshly regenerated client byte-matches the checked-in version
2. `pytest tests/test_endpoint_sync.py -v` — asserts parameter names, return types, and error response mappings for every endpoint

**Exit codes** (any non-zero fails the job):
- `2` fixtures drift (SQL changed without `export-fixtures`)
- `3` client content drift (fixtures changed without `sync-client`)
- `4` client directory missing or empty
- `5` pytest endpoint assertions failed

### Test 2: Reinstall App
```bash
./install_app.sh --host=$POSTGRES_HOST
```
- Verifies schema can be reinstalled over existing installation
- Tests idempotency of install script

### Test 3: Uninstall App
```bash
./uninstall_app.sh --host=$POSTGRES_HOST
```
- Verifies schema removal works correctly
- Tests cleanup of all HAFBE objects

## Prerequisites

Tests require:
1. **API Client Sync (Test 1)**: Only needs Python 3.12+ and Poetry. Does NOT require PostgreSQL or HAF data.
2. **Reinstall/Uninstall (Tests 2–3)**:
   - HAFBE schema already installed and synced to 5M blocks
   - PostgreSQL accessible at specified host
   - Submodules initialized (hafah, btracker, reptracker)

## Adding New Functional Tests

### Add Test to Existing Script

Edit `test_scripts.sh`:
```bash
echo "Test N. Description..."
./scripts/your_script.sh --host="$POSTGRES_HOST"
echo "Test completed successfully"
```

### Test New Script

1. Add test block to `test_scripts.sh`
2. Include descriptive echo statements
3. Rely on script's own exit codes for pass/fail
4. Keep test order logical (install before uninstall)

## Debugging Failures

### Check Script Output
Tests use `set -euo pipefail`, so first failing command stops execution. Look for:
- SQL errors in output
- Permission denied errors
- Missing dependencies

### Common Failure Causes

| Symptom | Cause | Solution |
|---------|-------|----------|
| Permission denied | Wrong PostgreSQL user | Use haf_admin user |
| Schema not found | HAFBE not installed | Install HAFBE first |
| Submodule error | Missing submodules | `git submodule update --init` |

### Manual Testing
Run individual scripts manually with verbose output:
```bash
./scripts/install_app.sh --host=localhost 2>&1 | tee install.log
./scripts/uninstall_app.sh --host=localhost 2>&1 | tee uninstall.log
```

## CI Integration

The `setup-scripts-test` job in `.gitlab-ci.yml`:
- Extends `.hafbe_test_base` template
- Initializes submodules before running tests
- Creates necessary directories for hafah setup
- Runs against synced 5M block database

Additionally, the dedicated `python_api_client_test` job also runs `scripts/check_api_client_sync.sh` directly — ensuring endpoint/client drift is caught on Python 3.12 and 3.14 even if the functional tests are somehow bypassed.

Both jobs fail hard on any exit code from `check_api_client_sync.sh`, blocking the merge request.

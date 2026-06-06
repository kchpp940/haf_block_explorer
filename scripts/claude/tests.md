# HAF Block Explorer - Testing Guide

## Overview

HAFBE uses a multi-layered testing strategy to ensure API correctness, data integrity, and performance:

| Test Type | Purpose | When to Run |
|-----------|---------|-------------|
| **Regression** | Verify data matches hived snapshots | After processing changes |
| **Tavern** | Validate API response patterns | After endpoint changes |
| **Performance** | Measure endpoint throughput | Before releases |
| **Functional** | Test install/uninstall scripts + API client sync | After script or endpoint changes |
| **Mock** | Drive a synthetic block range through the real processor + endpoints | When you cannot wait for a HAF sync past the feature's launch block (e.g. DHF launch at block ~22.3M) |
| **API Client Sync** | Verify Python client matches SQL endpoint schema | After ANY endpoint change; mandatory in CI |

## Quick Reference

### Run All Tests (CI does this)
```bash
# From project root, with synced database

# API Client Sync Check (always runs first — no database needed)
./scripts/check_api_client_sync.sh

# Regression tests
cd tests/regression && ./run_test.sh --host=localhost --type=all

# Tavern API tests (parallel)
cd tests/tavern/patterns-mainnet && pytest -n 8 .

# Performance tests
./tests/performance/run_performance_tests.sh --postgrest-host=localhost

# Functional tests
./tests/functional/test_scripts.sh --host=localhost
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `HAFBE_ADDRESS` | PostgREST host for Tavern tests | - |
| `HAFBE_PORT` | PostgREST port for Tavern tests | - |
| `POSTGRES_HOST` | PostgreSQL host | localhost |
| `POSTGRES_PORT` | PostgreSQL port | 5432 |
| `POSTGRES_USER` | PostgreSQL user | haf_admin |

## Test Categories

### Regression Tests
Compares HAFBE-computed account/witness data against hived node snapshots. Catches calculation errors and processing bugs.

**Key files:**
- `tests/regression/run_test.sh` - Main test runner
- `tests/regression/sql/02_compare.sql` - Comparison logic
- `tests/regression/accounts_dump.json.gz` - Expected account data
- `tests/regression/witnesses_dump.json.gz` - Expected witness data

[Detailed documentation](tests/regression.md)

### Tavern API Tests
YAML-based API pattern tests using pytest-tavern. Tests endpoint responses against expected patterns.

**Key files:**
- `tests/tavern/common.yaml` - Shared test configuration
- `tests/tavern/patterns-mainnet/` - Test cases organized by endpoint
- `tests/tavern/pytest.ini` - pytest markers configuration

[Detailed documentation](tests/tavern.md)

### Performance Tests
JMeter-based load testing to measure endpoint throughput and identify bottlenecks.

**Key files:**
- `tests/performance/endpoints.jmx` - JMeter test plan
- `tests/performance/run_performance_tests.sh` - Test runner
- `tests/performance/generate_db.py` - Test data generator

[Detailed documentation](tests/performance.md)

### Functional Tests
Verifies install/uninstall scripts work correctly.

**Key files:**
- `tests/functional/test_scripts.sh` - Script test runner

[Detailed documentation](tests/functional.md)

### Mock Tests
Drives a synthetic block range (currently 91000001..91000006) through the
real `hafbe_app.main` pipeline + endpoints, then asserts a fixed expected
state. Used for features whose ops only appear on mainnet past a launch
block that a partial-sync HAF has not yet processed (e.g. DHF / proposals
launched at block ~22.3M).

Three-step workflow (mirrors `submodules/btracker/tests/mocks`):

```bash
# 1. Load fixtures + rewind hafbe_app / hafbe_bal contexts
./tests/mocks/install_mock_data.sh --host=localhost --user=haf_admin

# 2. Run the regular block processor against the mock range
./scripts/process_blocks.sh --host=localhost --stop-at-block=91000006

# 3. Refresh caches and run the PASS/FAIL assertion table
./scripts/verify_mock_data.sh --host=localhost --user=haf_admin
```

Assumes a fresh HAFBE+btracker install. To re-run, fully uninstall both
apps then reinstall — see `tests/mocks/README.md` for the reset procedure.

**Key files:**
- `tests/mocks/install_mock_data.sh` - Loads fixtures, rewinds contexts
- `scripts/verify_mock_data.sh` - Refreshes caches, runs verify.sql
- `tests/mocks/sql/verify.sql` - 36 SQL assertions covering processor state, endpoint composition, status filters, sorting, and pagination
- `tests/mocks/fixtures/` - Mock block headers + operation bodies
- `tests/mocks/README.md` - Full documentation

**Tavern HTTP tests against mock data** (`tests/tavern/patterns-mock/`):
35 HTTP-level Tavern cases that run in CI against the mock cache (via `pattern-test-with-mock-data` job), each with a matching `.pat.json` response pattern. Organised by endpoint:
- `get_proposals/` — 14 positive (status×5, sort×8, pagination) + 5 negative
- `get_proposal_votes/` — 6 positive + 5 negative
- `get_proposal_votes_history/` — 2 positive + 3 negative

All patterns use `compare_rest_response_with_pattern` against `.pat.json` files. Add new tests here when adding proposal-related features that require mock data.

### API Client Sync Tests (Mandatory)

Ensures the auto-generated Python API client (`hiveio_hafbe_api/hafbe_api_client/`) stays in sync with the SQL endpoint definitions. These tests cannot be skipped and run in two CI jobs.

**Why this exists**: Developers modifying `endpoints/endpoint_schema.sql` or `endpoints/rewrite_rules.conf` used to forget to regenerate the Python client, causing downstream consumers to use stale method signatures.

**Check layers** (all must pass):

| Layer | Tool | Failure |
|-------|------|---------|
| OpenAPI fixture baseline | `generate_and_validate.py verify-fixtures` | exit 2 |
| Rewrite rules baseline | `generate_and_validate.py verify-fixtures` | exit 2 |
| Generated client exists | `generate_and_validate.py check-client` | exit 4 |
| Generated client content match | `generate_and_validate.py generate-diff --fail-on-change` | exit 3 |
| Parameter name mapping | `pytest tests/test_endpoint_sync.py` | AssertionError |
| Return type / schema ref | `pytest tests/test_endpoint_sync.py` | AssertionError |
| 4xx/5xx error response mapping | `pytest tests/test_endpoint_sync.py` | AssertionError |

**Key files:**
- `scripts/check_api_client_sync.sh` — Unified entry point (what CI runs)
- `scripts/api_generation/generate_and_validate.py` — CLI with `export-fixtures`, `verify-fixtures`, `check-client`, `generate-diff`, `sync-client`, `check-all` subcommands
- `scripts/api_generation/openapi_extractor.py` — Extracts and parses OpenAPI spec from `endpoint_schema.sql`
- `scripts/api_generation/rewrite_rules_parser.py` — Canonical ordering of rewrite rules
- `scripts/python_api_package/tests/test_endpoint_sync.py` — Pytest assertions (module-level hard fail on sync mismatch)
- `scripts/api_generation/fixtures/openapi_spec.json` — Committed baseline OpenAPI spec
- `scripts/api_generation/fixtures/rewrite_rules.conf` — Committed baseline rewrite rules

**Developer workflow after endpoint changes:**
```bash
# 1. Export new fixtures
python scripts/api_generation/generate_and_validate.py export-fixtures

# 2. Regenerate client
python scripts/api_generation/generate_and_validate.py sync-client

# 3. Verify (CI runs exactly this)
./scripts/check_api_client_sync.sh

# 4. Commit all three: endpoint changes + fixtures + generated client
git add endpoints/ scripts/api_generation/fixtures/ scripts/python_api_package/hiveio_hafbe_api/hafbe_api_client/
```

## CI/CD Integration

Tests run in GitLab CI pipeline (`.gitlab-ci.yml`):

```
detect → lint → build → sync → test → publish
                               ↑
                         Tests run here
```

### CI Test Jobs

| Job | Test Type | Artifacts |
|-----|-----------|-----------|
| `regression-test` | Regression | `regression_test.log` |
| `pattern-test` | Tavern (mainnet patterns) | JUnit XML report |
| `pattern-test-with-mock-data` | Tavern (mock patterns) | JUnit XML report |
| `performance-test` | Performance | HTML report, JUnit XML |
| `setup-scripts-test` | Functional + **API Client Sync** | - |
| `python_api_client_test` | **API Client Sync** + generated client integration | JUnit XML report |

`pattern-test` runs against the 5M-block mainnet sync cache. `pattern-test-with-mock-data` runs against the `haf_hafbe_mock` cache prepared by `sync_with_mock_data` — it covers endpoints whose data only exists in the synthetic 91M block range (proposals, DHF votes).

`setup-scripts-test` and `python_api_client_test` BOTH run `scripts/check_api_client_sync.sh`, which performs a 4-step check (fixture sync → client exists → client content diff → pytest endpoint assertions). If any SQL endpoint was modified without regenerating the client, both jobs fail hard and block the merge request.

### Pipeline Requirements

Tests require:
1. **HAF data**: Synced to 5M blocks (prepared by `prepare_haf_data` job)
2. **HAFBE schema**: Installed and synced (by `sync` job)
3. **PostgREST**: Running for API tests
4. **API client fixtures + generated files**: Must be committed alongside endpoint changes (validated by both `setup-scripts-test` and `python_api_client_test` before any database-dependent steps)

`pattern-test-with-mock-data` additionally requires the mock cache (`sync_with_mock_data` job, sync stage). That job:
- Checks NFS for a cached `haf_hafbe_mock` image; on miss, falls back to the HAFBE sync cache as base
- Runs `docker/docker-compose-mocks.yml` (HAF + fixture installer + block processor)
- Waits for `hive.is_app_in_sync('hafbe_app')` then runs `verify_mock_data.sh`
- Saves the resulting pgdata as `haf_hafbe_mock` cache

### Test Dependencies

```
find_haf_image → prepare_haf_data → sync              → tests
                                  ↘ sync_with_mock_data  ├── regression-test
                                                          ├── pattern-test
                                                          ├── pattern-test-with-mock-data
                                                          ├── performance-test
                                                          ├── setup-scripts-test      ← API Client Sync here
                                                          └── python_api_client_test    ← API Client Sync here
```

> Note: The API Client Sync check in `setup-scripts-test` runs BEFORE any database-dependent steps and requires no PostgreSQL. It catches endpoint/client drift as early as possible.

## Writing New Tests

### Adding Tests to Existing Categories

1. **Regression**: Add comparison logic to `tests/regression/sql/02_compare.sql`
2. **Tavern**: Create new `.tavern.yaml` in appropriate endpoint directory
3. **Performance**: Modify `tests/performance/endpoints.jmx`
4. **Functional**: Add tests to `tests/functional/test_scripts.sh`

### Creating a New Test Category

1. Create directory: `tests/<category>/`
2. Add test runner script with `--help` option
3. Create documentation: `scripts/claude/tests/<category>.md`
4. Add CI job in `.gitlab-ci.yml` extending `.hafbe_test_base`
5. Update this file with the new category

## Debugging Test Failures

### Common Issues

| Symptom | Cause | Solution |
|---------|-------|----------|
| Regression failure | Data mismatch | Check `hafbe_test.differing_*` tables |
| Tavern 500 error | SQL exception | Check PostgREST logs |
| Tavern pattern mismatch | Response structure changed | Update expected pattern files |
| Performance timeout | Slow query | Check `EXPLAIN ANALYZE` |

### CI Failure Investigation

1. Check job logs in GitLab
2. Download artifacts (container logs, test reports)
3. Look for `docker/container-logs.txt` for service logs
4. For Tavern: check `*.out.json` files for actual responses

## Expansion Rules

| Change Type | Action |
|-------------|--------|
| Add test to existing category | Update that category's `.md` file |
| Add new test category | Create `scripts/claude/tests/<category>.md` and update this file |
| Change test infrastructure | Update both this file and affected category docs |

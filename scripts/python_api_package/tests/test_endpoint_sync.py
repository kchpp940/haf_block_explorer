from __future__ import annotations

import importlib
import inspect
import json
import sys
import typing
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent
API_GEN_DIR = SCRIPTS_DIR / "api_generation"
PROJECT_ROOT = SCRIPTS_DIR.parent
sys.path.insert(0, str(API_GEN_DIR))

from openapi_extractor import (  # noqa: E402
    EndpointDef,
    load_openapi_spec,
)
from generate_and_validate import (  # noqa: E402
    FIXED_OPENAPI_JSON,
    verify_openapi_not_modified,
    verify_rewrite_rules_not_modified,
    run_generation_diff,
)


ENDPOINT_SCHEMA_SQL = PROJECT_ROOT / "endpoints" / "endpoint_schema.sql"
CLIENT_DIR = SCRIPTS_DIR / "python_api_package" / "hiveio_hafbe_api" / "hafbe_api_client"


def param_name_to_python(name: str) -> str:
    return name.replace("-", "_")


def operation_id_to_method_name(op_id: str) -> str:
    short = op_id.replace("hafbe_endpoints.", "")
    return short


def path_to_method_name(path: str) -> str:
    cleaned = path.strip("/").replace("/", "_").replace("{", "").replace("}", "")
    return cleaned


OPERATION_ID_TO_PATHS = {
    "hafbe_endpoints.get_witnesses": "/witnesses",
    "hafbe_endpoints.get_witness": "/witnesses/{account-name}",
    "hafbe_endpoints.get_witness_voters": "/witnesses/{account-name}/voters",
    "hafbe_endpoints.get_witness_voters_num": "/witnesses/{account-name}/voters/count",
    "hafbe_endpoints.get_witness_votes_history": "/witnesses/{account-name}/votes/history",
    "hafbe_endpoints.get_account": "/accounts/{account-name}",
    "hafbe_endpoints.get_account_authority": "/accounts/{account-name}/authority",
    "hafbe_endpoints.get_account_proxies_power": "/accounts/{account-name}/proxy-power",
    "hafbe_endpoints.get_comment_permlinks": "/accounts/{account-name}/comment-permlinks",
    "hafbe_endpoints.get_comment_operations": "/accounts/{account-name}/operations/comments/{permlink}",
    "hafbe_endpoints.get_total_wallet_addresses": "/total_wallet_addresses",
    "hafbe_endpoints.get_block_by_op": "/block-search",
    "hafbe_endpoints.get_proposals": "/proposals",
    "hafbe_endpoints.get_proposal_votes": "/proposals/votes",
    "hafbe_endpoints.get_proposal_votes_history": "/proposals/{proposal-id}/votes/history",
    "hafbe_endpoints.get_transaction_statistics": "/transaction-statistics",
    "hafbe_endpoints.get_operation_type_statistics": "/operation-type-statistics",
    "hafbe_endpoints.get_hafbe_version": "/version",
    "hafbe_endpoints.get_hafbe_last_synced_block": "/last-synced-block",
    "hafbe_endpoints.get_input_type": "/input-type/{input-value}",
    "hafbe_endpoints.get_latest_blocks": "/operation-type-counts",
}


def skip_if_client_not_generated():
    if not CLIENT_DIR.exists():
        pytest.skip("Generated client package not present. Run the generation pipeline first.")


def skip_if_fixtures_mismatch():
    ok_openapi, _ = verify_openapi_not_modified()
    ok_rules, _ = verify_rewrite_rules_not_modified()
    if not (ok_openapi and ok_rules):
        pytest.skip(
            "Fixtures out of sync with endpoint_schema.sql. "
            "Run `python scripts/api_generation/generate_and_validate.py export-fixtures`."
        )


def _load_generated_client_class():
    client_file = CLIENT_DIR / "hafbe_api_client.py"
    if not client_file.exists():
        return None
    spec = importlib.util.spec_from_file_location("hafbe_api_client_dynamic", client_file)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    for attr in dir(module):
        cls = getattr(module, attr)
        if isinstance(cls, type) and attr.endswith("Api"):
            return cls
    return None


def test_fixtures_are_in_sync_with_sql():
    ok_openapi, msg_openapi = verify_openapi_not_modified()
    ok_rules, msg_rules = verify_rewrite_rules_not_modified()
    assert ok_openapi, msg_openapi
    assert ok_rules, msg_rules


def test_fixed_openapi_spec_matches_expected_endpoints():
    data = json.loads(FIXED_OPENAPI_JSON.read_text(encoding="utf-8"))
    paths = set(data.get("paths", {}).keys())
    expected_paths = set(OPERATION_ID_TO_PATHS.values())
    assert paths == expected_paths, (
        f"OpenAPI paths mismatch.\n"
        f"Missing: {sorted(expected_paths - paths)}\n"
        f"Extra:   {sorted(paths - expected_paths)}"
    )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_client_package_directory_exists():
    assert CLIENT_DIR.exists()
    init_files = list(CLIENT_DIR.glob("*.py"))
    assert len(init_files) > 0, "Client package should contain Python modules"


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_generated_client_matches_fixture_baseline():
    skip_if_fixtures_mismatch()
    result = run_generation_diff()
    assert result.identical, (
        "Checked-in generated client differs from what the fixed OpenAPI fixture produces.\n"
        + __import__("generate_and_validate", fromlist=["format_diff_report"]).format_diff_report(result)
        + "\nRun `python scripts/api_generation/generate_and_validate.py sync-client` to regenerate."
    )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_every_endpoint_has_corresponding_client_method():
    skip_if_client_not_generated()
    skip_if_fixtures_mismatch()
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    client_cls = _load_generated_client_class()
    assert client_cls is not None, "Could not locate generated API client class"

    methods = {name for name, _ in inspect.getmembers(client_cls, predicate=inspect.isfunction)}
    methods |= {name for name, _ in inspect.getmembers(client_cls, predicate=inspect.ismethod)}

    for ep in spec.endpoints:
        method_candidates = [
            operation_id_to_method_name(ep.operation_id),
            path_to_method_name(ep.path),
        ]
        found = any(c in methods for c in method_candidates)
        assert found, (
            f"Endpoint {ep.operation_id} (path={ep.path}) has no matching client method. "
            f"Candidates checked: {method_candidates}. Available methods: {sorted(methods)}"
        )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_get_account_parameter_names_match():
    skip_if_client_not_generated()
    skip_if_fixtures_mismatch()
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_account")
    assert ep is not None

    client_cls = _load_generated_client_class()
    assert client_cls is not None
    fn = getattr(client_cls, "get_account", None) or getattr(
        client_cls, "accounts_account_name", None
    )
    assert fn is not None, "get_account method not found on generated client"

    sig = inspect.signature(fn)
    param_names = list(sig.parameters.keys())
    expected = [param_name_to_python(p.name) for p in ep.parameters]
    for e in expected:
        assert e in param_names, (
            f"get_account missing expected parameter '{e}'. Actual params: {param_names}"
        )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_get_witness_voters_parameter_names_match():
    skip_if_client_not_generated()
    skip_if_fixtures_mismatch()
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_witness_voters")
    assert ep is not None

    client_cls = _load_generated_client_class()
    assert client_cls is not None
    fn = None
    for candidate in ["get_witness_voters", "witnesses_account_name_voters"]:
        if hasattr(client_cls, candidate):
            fn = getattr(client_cls, candidate)
            break
    assert fn is not None, "get_witness_voters method not found on generated client"

    sig = inspect.signature(fn)
    param_names = list(sig.parameters.keys())
    expected = [param_name_to_python(p.name) for p in ep.parameters]
    for e in expected:
        assert e in param_names, (
            f"get_witness_voters missing expected parameter '{e}'. Actual params: {param_names}"
        )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_endpoints_with_error_responses_have_correct_mapping():
    skip_if_client_not_generated()
    skip_if_fixtures_mismatch()
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)

    error_endpoints = [
        ("hafbe_endpoints.get_account", {"404": "No such account in the database"}),
        ("hafbe_endpoints.get_witness", {"404": "No such witness"}),
        ("hafbe_endpoints.get_witness_voters", {"404": "No such witness"}),
        ("hafbe_endpoints.get_total_wallet_addresses", {"400": "Invalid block range or parameter"}),
    ]

    for op_id, expected_errors in error_endpoints:
        ep = spec.endpoint_by_operation_id(op_id)
        assert ep is not None
        actual_errors = {
            r.status_code: r.description.strip()
            for r in ep.responses
            if r.status_code.startswith("4") or r.status_code.startswith("5")
        }
        for code, desc in expected_errors.items():
            assert code in actual_errors, f"{op_id} missing error response {code}"
            assert desc in actual_errors[code], (
                f"{op_id} error {code} description mismatch: expected '{desc}' got '{actual_errors[code]}'"
            )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_return_type_schemas_are_present_for_200_responses():
    skip_if_client_not_generated()
    skip_if_fixtures_mismatch()
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)

    schema_endpoints = [
        ("hafbe_endpoints.get_account", "#/components/schemas/hafbe_backend.account"),
        ("hafbe_endpoints.get_account_authority", "#/components/schemas/hafbe_backend.account_authority"),
        ("hafbe_endpoints.get_witness", "#/components/schemas/hafbe_backend.witness"),
        ("hafbe_endpoints.get_witnesses", "#/components/schemas/hafbe_backend.witnesses_return"),
        ("hafbe_endpoints.get_block_by_op", "#/components/schemas/hafbe_backend.block_history"),
        ("hafbe_endpoints.get_proposals", "#/components/schemas/hafbe_backend.proposals_return"),
    ]

    for op_id, expected_ref in schema_endpoints:
        ep = spec.endpoint_by_operation_id(op_id)
        assert ep is not None, f"Missing endpoint: {op_id}"
        resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
        assert resp_200 is not None, f"{op_id} has no 200 response"
        assert resp_200.schema_ref == expected_ref, (
            f"{op_id} 200 schema ref mismatch: expected {expected_ref}, got {resp_200.schema_ref}"
        )


@pytest.mark.skipif(not CLIENT_DIR.exists(), reason="Generated client not present")
def test_primitive_return_types_are_correct():
    skip_if_client_not_generated()
    skip_if_fixtures_mismatch()
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)

    primitive_endpoints = [
        ("hafbe_endpoints.get_hafbe_version", "string"),
        ("hafbe_endpoints.get_hafbe_last_synced_block", "integer"),
        ("hafbe_endpoints.get_witness_voters_num", "integer"),
    ]

    for op_id, expected_type in primitive_endpoints:
        ep = spec.endpoint_by_operation_id(op_id)
        assert ep is not None
        resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
        assert resp_200 is not None
        assert resp_200.schema_type == expected_type, (
            f"{op_id} expected primitive return type '{expected_type}', got '{resp_200.schema_type}'"
        )
        assert resp_200.schema_ref is None, (
            f"{op_id} should not have a schema $ref for primitive return"
        )

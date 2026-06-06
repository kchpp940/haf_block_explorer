from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

API_GEN_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = API_GEN_DIR.parent.parent
sys.path.insert(0, str(API_GEN_DIR))

from openapi_extractor import (  # noqa: E402
    EndpointDef,
    EndpointParam,
    EndpointResponse,
    extract_openapi_from_sql,
    load_openapi_spec,
    parse_endpoints,
)


ENDPOINT_SCHEMA_SQL = PROJECT_ROOT / "endpoints" / "endpoint_schema.sql"
FIXTURE_OPENAPI = API_GEN_DIR / "fixtures" / "openapi_spec.json"


EXPECTED_OPERATION_IDS = [
    "hafbe_endpoints.get_witnesses",
    "hafbe_endpoints.get_witness",
    "hafbe_endpoints.get_witness_voters",
    "hafbe_endpoints.get_witness_voters_num",
    "hafbe_endpoints.get_witness_votes_history",
    "hafbe_endpoints.get_account",
    "hafbe_endpoints.get_account_authority",
    "hafbe_endpoints.get_account_proxies_power",
    "hafbe_endpoints.get_comment_permlinks",
    "hafbe_endpoints.get_comment_operations",
    "hafbe_endpoints.get_total_wallet_addresses",
    "hafbe_endpoints.get_block_by_op",
    "hafbe_endpoints.get_proposals",
    "hafbe_endpoints.get_proposal_votes",
    "hafbe_endpoints.get_proposal_votes_history",
    "hafbe_endpoints.get_transaction_statistics",
    "hafbe_endpoints.get_operation_type_statistics",
    "hafbe_endpoints.get_hafbe_version",
    "hafbe_endpoints.get_hafbe_last_synced_block",
    "hafbe_endpoints.get_input_type",
    "hafbe_endpoints.get_latest_blocks",
]


def test_endpoint_schema_sql_exists():
    assert ENDPOINT_SCHEMA_SQL.exists(), f"Missing {ENDPOINT_SCHEMA_SQL}"


def test_fixture_openapi_exists():
    assert FIXTURE_OPENAPI.exists(), f"Missing fixture {FIXTURE_OPENAPI}. Run `python generate_and_validate.py export-fixtures`"


def test_extract_openapi_from_sql_produces_valid_json():
    spec = extract_openapi_from_sql(ENDPOINT_SCHEMA_SQL)
    assert isinstance(spec, dict)
    assert "openapi" in spec
    assert "paths" in spec
    assert "components" in spec


def test_fixture_openapi_matches_sql_source():
    from_sql = extract_openapi_from_sql(ENDPOINT_SCHEMA_SQL)
    from_fixture = json.loads(FIXTURE_OPENAPI.read_text(encoding="utf-8"))
    assert from_sql == from_fixture, (
        "OpenAPI fixture does not match endpoint_schema.sql. "
        "Re-run `python scripts/api_generation/generate_and_validate.py export-fixtures` "
        "after updating the SQL endpoints."
    )


def test_all_expected_operation_ids_present():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    op_ids = sorted(ep.operation_id for ep in spec.endpoints)
    expected = sorted(EXPECTED_OPERATION_IDS)
    assert op_ids == expected, (
        f"Endpoint operation IDs mismatch.\n"
        f"Missing: {sorted(set(expected) - set(op_ids))}\n"
        f"Extra:   {sorted(set(op_ids) - set(expected))}"
    )


def test_each_endpoint_has_get_method():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    for ep in spec.endpoints:
        assert ep.method.lower() == "get", f"Endpoint {ep.path} uses non-GET method {ep.method}"


def test_each_endpoint_has_200_response():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    for ep in spec.endpoints:
        codes = {r.status_code for r in ep.responses}
        assert "200" in codes, f"Endpoint {ep.operation_id} missing 200 response (has: {sorted(codes)})"


def test_get_account_param_names():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_account")
    assert ep is not None
    param_names = [p.name for p in ep.parameters]
    assert param_names == ["account-name"]
    path_params = [p for p in ep.parameters if p.location == "path"]
    assert len(path_params) == 1
    assert path_params[0].required is True
    assert path_params[0].schema_type == "string"


def test_get_witness_voters_param_names_and_order():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_witness_voters")
    assert ep is not None
    param_names = [p.name for p in ep.parameters]
    assert param_names == [
        "account-name",
        "voter-name",
        "page",
        "page-size",
        "sort",
        "direction",
    ]
    path_params = [p for p in ep.parameters if p.location == "path"]
    query_params = [p for p in ep.parameters if p.location == "query"]
    assert len(path_params) == 1
    assert path_params[0].name == "account-name"
    assert len(query_params) == 5


def test_get_proposals_has_all_query_params():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_proposals")
    assert ep is not None
    param_names = [p.name for p in ep.parameters]
    for expected in ["page", "page-size", "sort", "direction", "status", "creator", "proposal-ids", "voter", "search"]:
        assert expected in param_names, f"get_proposals missing param: {expected}"


def test_get_account_has_404_error_response():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_account")
    assert ep is not None
    codes = {r.status_code for r in ep.responses}
    assert "404" in codes, f"get_account missing 404 response (has: {sorted(codes)})"


def test_get_total_wallet_addresses_has_400_error_response():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_total_wallet_addresses")
    assert ep is not None
    codes = {r.status_code for r in ep.responses}
    assert "400" in codes, f"get_total_wallet_addresses missing 400 response (has: {sorted(codes)})"


def test_get_block_by_op_return_schema_ref():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_block_by_op")
    assert ep is not None
    resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
    assert resp_200 is not None
    assert resp_200.schema_ref == "#/components/schemas/hafbe_backend.block_history"


def test_get_account_return_schema_ref():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_account")
    assert ep is not None
    resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
    assert resp_200 is not None
    assert resp_200.schema_ref == "#/components/schemas/hafbe_backend.account"


def test_get_hafbe_version_returns_primitive_string():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_hafbe_version")
    assert ep is not None
    resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
    assert resp_200 is not None
    assert resp_200.schema_type == "string"
    assert resp_200.schema_ref is None


def test_get_hafbe_last_synced_block_returns_primitive_integer():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_hafbe_last_synced_block")
    assert ep is not None
    resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
    assert resp_200 is not None
    assert resp_200.schema_type == "integer"
    assert resp_200.schema_ref is None


def test_all_error_responses_have_descriptions():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    for ep in spec.endpoints:
        for resp in ep.responses:
            code = resp.status_code
            if code.startswith("4") or code.startswith("5"):
                assert resp.description.strip(), (
                    f"Endpoint {ep.operation_id} error response {code} has empty description"
                )


def test_parse_endpoints_preserves_path():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_path("/accounts/{account-name}")
    assert ep is not None
    assert ep.operation_id == "hafbe_endpoints.get_account"


def test_enum_schemas_exist_in_components():
    spec_raw = extract_openapi_from_sql(ENDPOINT_SCHEMA_SQL)
    schemas = spec_raw.get("components", {}).get("schemas", {})
    for name in [
        "hafbe_backend.comment_type",
        "hafbe_backend.sort_direction",
        "hafbe_backend.order_by_votes",
        "hafbe_backend.order_by_witness",
        "hafbe_backend.proposal_status",
        "hafbe_backend.granularity",
    ]:
        assert name in schemas, f"Missing schema definition: {name}"
        schema = schemas[name]
        assert schema.get("type") == "string"
        assert "enum" in schema, f"Schema {name} should be an enum"


def test_spec_version_present():
    spec_raw = extract_openapi_from_sql(ENDPOINT_SCHEMA_SQL)
    info = spec_raw.get("info", {})
    assert "version" in info
    assert "title" in info
    assert info["title"] == "HAF Block Explorer"

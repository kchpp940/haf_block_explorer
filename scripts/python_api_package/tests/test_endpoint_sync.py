from __future__ import annotations

import importlib
import inspect
import json
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent
API_GEN_DIR = SCRIPTS_DIR / "api_generation"
PROJECT_ROOT = SCRIPTS_DIR.parent
sys.path.insert(0, str(API_GEN_DIR))

from generate_and_validate import (  # noqa: E402
    check_client_exists,
    verify_openapi_not_modified,
    verify_rewrite_rules_not_modified,
)

_OK_FIXTURES, _MSG_FIXTURES = verify_openapi_not_modified()
_OK_RULES, _MSG_RULES = verify_rewrite_rules_not_modified()
_OK_CLIENT, _MSG_CLIENT = check_client_exists()

if not (_OK_FIXTURES and _OK_RULES):
    raise AssertionError(
        "ENDPOINT SYNC CHECK FAILED (test_endpoint_sync pre-collection):\n"
        f"  {_MSG_FIXTURES}\n"
        f"  {_MSG_RULES}\n"
        "\nRun: python scripts/api_generation/generate_and_validate.py export-fixtures\n"
        "after modifying endpoints/endpoint_schema.sql or endpoints/rewrite_rules.conf,\n"
        "then re-run the client generation and commit both the fixture and client changes."
    )

if not _OK_CLIENT:
    raise AssertionError(
        "ENDPOINT SYNC CHECK FAILED (test_endpoint_sync pre-collection):\n"
        f"  {_MSG_CLIENT}\n"
        "\nRun: python scripts/api_generation/generate_and_validate.py sync-client\n"
        "and commit the generated files under scripts/python_api_package/hiveio_hafbe_api/hafbe_api_client/."
    )

from openapi_extractor import (  # noqa: E402
    load_openapi_spec,
)
from generate_and_validate import (  # noqa: E402
    FIXED_OPENAPI_JSON,
    format_diff_report,
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
    segments = []
    for seg in path.strip("/").split("/"):
        if seg.startswith("{") and seg.endswith("}"):
            continue
        segments.append(seg.replace("-", "_"))
    return "_".join(segments)


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


def _load_generated_client_class():
    client_file = CLIENT_DIR / "hafbe_api_client.py"
    assert client_file.exists(), (
        f"Generated client file not found: {client_file}. "
        "Run `python scripts/api_generation/generate_and_validate.py sync-client`."
    )
    module_name = "hafbe_api_client_dynamic"
    spec = importlib.util.spec_from_file_location(module_name, client_file)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    for attr in dir(module):
        cls = getattr(module, attr)
        if (
            isinstance(cls, type)
            and attr.endswith("Api")
            and cls.__module__ == module_name
        ):
            return cls
    raise AssertionError(
        "Could not locate generated API client class in hafbe_api_client.py. "
        "The client generator may have changed its output convention."
    )


def _get_client_methods(client_cls: type) -> set[str]:
    methods: set[str] = set()
    for name in dir(client_cls):
        if name.startswith("_"):
            continue
        val = getattr(client_cls, name, None)
        if callable(val) or inspect.iscoroutinefunction(val) or inspect.isfunction(val) or inspect.ismethod(val):
            methods.add(name)
    return methods


def test_client_package_directory_exists_and_has_modules():
    assert CLIENT_DIR.exists(), (
        f"Generated client directory missing: {CLIENT_DIR}. "
        "Run `python scripts/api_generation/generate_and_validate.py sync-client` "
        "and commit the generated files."
    )
    py_files = list(CLIENT_DIR.glob("*.py"))
    assert len(py_files) > 0, (
        "Client package directory exists but contains no .py modules. "
        "Regenerate with `python scripts/api_generation/generate_and_validate.py sync-client`."
    )


def test_fixtures_are_in_sync_with_sql():
    from generate_and_validate import verify_openapi_not_modified, verify_rewrite_rules_not_modified
    ok_openapi, msg_openapi = verify_openapi_not_modified()
    ok_rules, msg_rules = verify_rewrite_rules_not_modified()
    assert ok_openapi, (
        f"OpenAPI fixtures out of date with endpoint_schema.sql.\n"
        f"{msg_openapi}\n"
        "Run `python scripts/api_generation/generate_and_validate.py export-fixtures` "
        "after modifying SQL endpoints."
    )
    assert ok_rules, (
        f"Rewrite rules fixtures out of date.\n"
        f"{msg_rules}\n"
        "Run `python scripts/api_generation/generate_and_validate.py export-fixtures`."
    )


def test_fixed_openapi_spec_matches_expected_endpoints():
    data = json.loads(FIXED_OPENAPI_JSON.read_text(encoding="utf-8"))
    paths = set(data.get("paths", {}).keys())
    expected_paths = set(OPERATION_ID_TO_PATHS.values())
    assert paths == expected_paths, (
        f"OpenAPI paths mismatch.\n"
        f"Missing: {sorted(expected_paths - paths)}\n"
        f"Extra:   {sorted(paths - expected_paths)}\n"
        "Update OPERATION_ID_TO_PATHS mapping and re-export fixtures after adding/removing endpoints."
    )


def test_generated_client_matches_fixture_baseline():
    result, report = run_generation_diff(require_client=True)
    assert result is not None, (
        f"Could not perform generation diff:\n{report}"
    )
    assert result.identical, (
        "Checked-in generated client differs from what the fixed OpenAPI fixture produces.\n"
        f"{report}\n"
        "Run `python scripts/api_generation/generate_and_validate.py sync-client` "
        "and commit the regenerated client files."
    )


def test_every_endpoint_has_corresponding_client_method():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    client_cls = _load_generated_client_class()

    methods = _get_client_methods(client_cls)

    missing: list[str] = []
    for ep in spec.endpoints:
        method_candidates = [
            operation_id_to_method_name(ep.operation_id),
            path_to_method_name(ep.path),
        ]
        found = any(c in methods for c in method_candidates)
        if not found:
            missing.append(f"{ep.operation_id} (path={ep.path}, candidates={method_candidates})")

    assert not missing, (
        "The following endpoints have no corresponding method on the generated client:\n  - "
        + "\n  - ".join(missing)
        + "\n\nRegenerate the client with `python scripts/api_generation/generate_and_validate.py sync-client`."
    )


def test_get_account_parameter_names_match():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_account")
    assert ep is not None

    client_cls = _load_generated_client_class()
    fn = getattr(client_cls, "get_account", None) or getattr(
        client_cls, path_to_method_name(ep.path), None
    )
    assert fn is not None, (
        "get_account method not found on generated client. "
        f"Looked for 'get_account' and '{path_to_method_name(ep.path)}'. "
        "Regenerate with `python scripts/api_generation/generate_and_validate.py sync-client`."
    )

    sig = inspect.signature(fn)
    param_names = list(sig.parameters.keys())
    expected = [param_name_to_python(p.name) for p in ep.parameters]
    for e in expected:
        assert e in param_names, (
            f"get_account missing expected parameter '{e}'. "
            f"Actual params: {param_names}. "
            "The generated client signature does not match the endpoint schema. "
            "Re-run sync-client."
        )


def test_get_witness_voters_parameter_names_match():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)
    ep = spec.endpoint_by_operation_id("hafbe_endpoints.get_witness_voters")
    assert ep is not None

    client_cls = _load_generated_client_class()
    fn = None
    path_based = path_to_method_name(ep.path)
    for candidate in ["get_witness_voters", path_based]:
        if hasattr(client_cls, candidate):
            fn = getattr(client_cls, candidate)
            break
    assert fn is not None, (
        "get_witness_voters method not found on generated client. "
        f"Looked for 'get_witness_voters' and '{path_based}'. "
        "Regenerate with `python scripts/api_generation/generate_and_validate.py sync-client`."
    )

    sig = inspect.signature(fn)
    param_names = list(sig.parameters.keys())
    expected = [param_name_to_python(p.name) for p in ep.parameters]
    for e in expected:
        assert e in param_names, (
            f"get_witness_voters missing expected parameter '{e}'. "
            f"Actual params: {param_names}. "
            "Regenerate the client — the endpoint schema parameters may have changed."
        )


def test_endpoints_with_error_responses_have_correct_mapping_in_schema():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)

    error_endpoints = [
        ("hafbe_endpoints.get_account", {"404": "No such account in the database"}),
        ("hafbe_endpoints.get_witness", {"404": "No such witness"}),
        ("hafbe_endpoints.get_witness_voters", {"404": "No such witness"}),
        ("hafbe_endpoints.get_total_wallet_addresses", {"400": "Invalid block range or parameter"}),
    ]

    for op_id, expected_errors in error_endpoints:
        ep = spec.endpoint_by_operation_id(op_id)
        assert ep is not None, f"Endpoint {op_id} missing from schema"
        actual_errors = {
            r.status_code: r.description.strip()
            for r in ep.responses
            if r.status_code.startswith("4") or r.status_code.startswith("5")
        }
        for code, desc in expected_errors.items():
            assert code in actual_errors, (
                f"{op_id} missing error response code {code}. "
                f"Defined error codes: {sorted(actual_errors.keys())}. "
                "Check endpoints/endpoint_schema.sql and re-export fixtures if changed."
            )
            assert desc in actual_errors[code], (
                f"{op_id} error {code} description mismatch.\n"
                f"Expected fragment: '{desc}'\n"
                f"Got:                 '{actual_errors[code]}'\n"
                "This usually means the endpoint SQL definition was changed without regenerating fixtures + client."
            )


def test_return_type_schemas_are_present_for_200_responses():
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
        assert resp_200 is not None, f"{op_id} has no 200 response defined"
        assert resp_200.schema_ref == expected_ref, (
            f"{op_id} 200 response schema ref mismatch.\n"
            f"Expected: {expected_ref}\n"
            f"Got:      {resp_200.schema_ref}\n"
            "The endpoint return type was changed in SQL but the generated client was not refreshed. "
            "Run export-fixtures + sync-client."
        )


def test_primitive_return_types_are_correct_in_schema():
    spec = load_openapi_spec(ENDPOINT_SCHEMA_SQL)

    primitive_endpoints = [
        ("hafbe_endpoints.get_hafbe_version", "string"),
        ("hafbe_endpoints.get_hafbe_last_synced_block", "integer"),
        ("hafbe_endpoints.get_witness_voters_num", "integer"),
    ]

    for op_id, expected_type in primitive_endpoints:
        ep = spec.endpoint_by_operation_id(op_id)
        assert ep is not None, f"Missing endpoint: {op_id}"
        resp_200 = next((r for r in ep.responses if r.status_code == "200"), None)
        assert resp_200 is not None, f"{op_id} has no 200 response"
        assert resp_200.schema_type == expected_type, (
            f"{op_id} expected primitive return type '{expected_type}', "
            f"got '{resp_200.schema_type}'. "
            "The endpoint SQL schema changed — re-export fixtures and regenerate client."
        )
        assert resp_200.schema_ref is None, (
            f"{op_id} should return a primitive '{expected_type}' without a schema $ref, "
            f"but got ref={resp_200.schema_ref}."
        )

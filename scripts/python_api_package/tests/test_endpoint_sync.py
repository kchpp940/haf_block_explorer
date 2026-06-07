from __future__ import annotations

import inspect
import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[3]
API_GEN_DIR = PROJECT_ROOT / "scripts" / "api_generation"
if str(API_GEN_DIR) not in sys.path:
    sys.path.insert(0, str(API_GEN_DIR))

from generate_and_validate import (
    _collect_expected_endpoints,
    _param_name_to_python,
    validate_client_file,
)
from openapi_extractor import load_openapi_spec


def _load_openapi_fixture() -> dict:
    fixture = (
        PROJECT_ROOT
        / "scripts"
        / "api_generation"
        / "fixtures"
        / "openapi_spec.json"
    )
    if not fixture.exists():
        pytest.fail(f"OpenAPI fixture not found: {fixture}")
    return load_openapi_spec(fixture)


def _get_client_file() -> Path:
    return (
        PROJECT_ROOT
        / "scripts"
        / "python_api_package"
        / "hiveio_hafbe_api"
        / "hafbe_api_client"
        / "hafbe_api_client.py"
    )


def test_client_directory_exists() -> None:
    client_dir = _get_client_file().parent
    if not client_dir.is_dir():
        pytest.fail(
            f"Generated client directory missing: {client_dir}\n"
            "Run: cd scripts/api_generation && poetry run python generate_and_validate.py sync-client"
        )
    py_files = list(client_dir.glob("*.py"))
    if not py_files:
        pytest.fail(f"No .py files in client directory: {client_dir}")


def test_client_class_importable() -> None:
    try:
        from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi
    except Exception as exc:
        pytest.fail(f"Cannot import HafbeApi from generated client: {exc}")
    assert inspect.isclass(HafbeApi), "HafbeApi must be a class"


def test_endpoint_count_matches_fixture() -> None:
    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi

    spec = _load_openapi_fixture()
    expected = _collect_expected_endpoints(spec)
    expected_names = {ep["method_name"] for ep in expected if ep["method_name"]}

    public_methods = {
        name
        for name, _ in inspect.getmembers(HafbeApi, predicate=inspect.iscoroutinefunction)
        if not name.startswith("_")
    }

    missing = expected_names - public_methods
    if missing:
        pytest.fail(
            f"HafbeApi missing {len(missing)} methods defined in OpenAPI fixture: "
            f"{sorted(missing)}"
        )


def test_key_endpoints_method_signatures() -> None:
    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi

    spec = _load_openapi_fixture()
    expected = _collect_expected_endpoints(spec)

    key_paths = {
        "/accounts/{account-name}",
        "/witnesses/{account-name}",
        "/proposals",
    }
    key_endpoints = [ep for ep in expected if ep["path"] in key_paths]
    assert key_endpoints, f"No key endpoints found in fixture among {key_paths}"

    for ep in key_endpoints:
        mname = ep["method_name"]
        assert hasattr(HafbeApi, mname), (
            f"Expected method HafbeApi.{mname} for {ep['http_method']} {ep['path']}"
        )
        method = getattr(HafbeApi, mname)
        sig = inspect.signature(method)
        param_names = list(sig.parameters.keys())
        for p in ep["parameters"]:
            if not p:
                continue
            assert p in param_names, (
                f"HafbeApi.{mname} missing parameter '{p}' "
                f"(signature has {param_names}; expected from {ep['http_method']} {ep['path']})"
            )


def test_endpoint_responses_and_error_mapping() -> None:
    spec = _load_openapi_fixture()
    expected = _collect_expected_endpoints(spec)

    no_success_resp = [
        f"{ep['http_method']} {ep['path']}"
        for ep in expected
        if "200" not in ep["responses"] and "default" not in ep["responses"]
    ]
    if no_success_resp:
        pytest.fail(
            f"{len(no_success_resp)} endpoints have no 200/default response:\n  - "
            + "\n  - ".join(no_success_resp)
        )

    error_endpoints = [
        ep
        for ep in expected
        if any(r.startswith(("4", "5")) for r in ep["responses"])
    ]
    if not error_endpoints:
        pytest.fail(
            "OpenAPI fixture declares zero 4xx/5xx error responses — "
            "cannot verify error mapping; check fixture integrity"
        )


def test_client_file_schema_validation() -> None:
    spec = _load_openapi_fixture()
    client_file = _get_client_file()

    ok, errors = validate_client_file(client_file, spec)
    if not ok:
        pytest.fail(
            "Generated client does not match OpenAPI fixture:\n  - "
            + "\n  - ".join(errors)
        )

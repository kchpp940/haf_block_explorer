from __future__ import annotations

import inspect
import json
from pathlib import Path
from typing import Any

import pytest

PROJECT_ROOT: Path = Path(__file__).resolve().parents[3]
FIXTURE_PATH: Path = PROJECT_ROOT / "scripts" / "api_generation" / "fixtures" / "openapi_spec.json"
CLIENT_DIR: Path = (
    PROJECT_ROOT / "scripts" / "python_api_package" / "hiveio_hafbe_api" / "hafbe_api_client"
)

OPERATION_ID_PREFIX: str = "hafbe_endpoints.get_"


def _load_openapi_fixture() -> dict[str, Any]:
    assert FIXTURE_PATH.exists(), f"OpenAPI fixture file not found at: {FIXTURE_PATH}"
    with FIXTURE_PATH.open(encoding="utf-8") as f:
        return json.load(f)


def _collect_operations(spec: dict[str, Any]) -> list[tuple[str, str, str, list[str], list[str]]]:
    operations: list[tuple[str, str, str, list[str], list[str]]] = []
    for path, path_item in spec.get("paths", {}).items():
        for method, operation in path_item.items():
            if method.lower() not in {"get", "post", "put", "delete", "patch"}:
                continue
            operation_id: str = operation.get("operationId", "")
            params: list[str] = [p.get("name", "") for p in operation.get("parameters", [])]
            responses: list[str] = list(operation.get("responses", {}).keys())
            operations.append((method.upper(), path, operation_id, params, responses))
    return operations


def _operation_id_to_method_name(operation_id: str) -> str:
    if not operation_id.startswith(OPERATION_ID_PREFIX):
        pytest.fail(f"Unexpected operationId format: {operation_id}")
    suffix: str = operation_id[len(OPERATION_ID_PREFIX) :]
    return suffix


def _path_to_method_name(path: str) -> str:
    segments: list[str] = [
        s.replace("-", "_") for s in path.strip("/").split("/") if not s.startswith("{")
    ]
    return "_".join(segments)


def _get_client_public_methods() -> set[str]:
    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi
    from beekeepy._apis.abc.api import AbstractAsyncApi

    base_methods: set[str] = set(dir(AbstractAsyncApi))
    all_attrs: set[str] = set(dir(HafbeApi))
    return {m for m in (all_attrs - base_methods) if not m.startswith("_")}


def test_client_directory_exists() -> None:
    assert CLIENT_DIR.exists(), (
        f"Client directory does not exist at: {CLIENT_DIR}"
    )
    assert CLIENT_DIR.is_dir(), (
        f"Client path is not a directory: {CLIENT_DIR}"
    )
    py_files: list[Path] = list(CLIENT_DIR.glob("*.py"))
    assert py_files, (
        f"No .py files found in client directory: {CLIENT_DIR}"
    )


def test_client_class_importable() -> None:
    try:
        from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi  # noqa: F401
    except (ImportError, ModuleNotFoundError) as exc:
        pytest.fail(f"Failed to import HafbeApi class: {exc}")

    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi

    assert inspect.isclass(HafbeApi), "HafbeApi is not a class"


def test_endpoint_count_matches_fixture() -> None:
    spec: dict[str, Any] = _load_openapi_fixture()
    operations: list[tuple[str, str, str, list[str], list[str]]] = _collect_operations(spec)
    assert operations, "No operations found in OpenAPI fixture"

    fixture_method_names: set[str] = {
        _path_to_method_name(path) for _, path, _, _, _ in operations
    }
    client_methods: set[str] = _get_client_public_methods()
    assert client_methods, "No public methods found on HafbeApi class"

    assert len(client_methods) >= len(fixture_method_names), (
        f"Client public method count ({len(client_methods)}) should be >= "
        f"unique fixture method count ({len(fixture_method_names)}). "
        f"Fixture methods: {sorted(fixture_method_names)}. "
        f"Client methods: {sorted(client_methods)}"
    )


def test_key_endpoints_method_signatures() -> None:
    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi

    spec: dict[str, Any] = _load_openapi_fixture()
    operations: list[tuple[str, str, str, list[str], list[str]]] = _collect_operations(spec)

    key_paths: list[str] = ["/accounts/{account-name}", "/witnesses/{account-name}", "/proposals"]

    for key_path in key_paths:
        matching_ops: list[tuple[str, str, str, list[str], list[str]]] = [
            op for op in operations if op[1] == key_path
        ]
        assert matching_ops, (
            f"Key path {key_path} not found in OpenAPI fixture operations"
        )

        for method, path, operation_id, params, responses in matching_ops:
            expected_method_name: str = _path_to_method_name(path)
            assert hasattr(HafbeApi, expected_method_name), (
                f"HafbeApi missing method '{expected_method_name}' "
                f"for path {path} (operationId={operation_id})"
            )

            method_obj = getattr(HafbeApi, expected_method_name)
            assert callable(method_obj), (
                f"HafbeApi.{expected_method_name} is not callable"
            )

            sig: inspect.Signature = inspect.signature(method_obj)
            sig_params: list[str] = list(sig.parameters.keys())

            for param_name in params:
                python_param_name: str = param_name.replace("-", "_")
                assert python_param_name in sig_params, (
                    f"Method HafbeApi.{expected_method_name} signature missing "
                    f"parameter '{python_param_name}' (from OpenAPI param '{param_name}'). "
                    f"Actual signature params: {sig_params}"
                )


def test_endpoint_responses_map_errors() -> None:
    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi

    assert HafbeApi is not None, "HafbeApi client class could not be imported"

    spec: dict[str, Any] = _load_openapi_fixture()
    operations: list[tuple[str, str, str, list[str], list[str]]] = _collect_operations(spec)

    for method, path, operation_id, params, responses in operations:
        assert "200" in responses, (
            f"Operation {operation_id} ({method} {path}) is missing 200 response in fixture. "
            f"Found responses: {responses}"
        )

        has_error_responses: bool = any(
            r.startswith("4") or r.startswith("5") for r in responses
        )
        if has_error_responses:
            expected_method_name: str = _path_to_method_name(path)
            assert hasattr(HafbeApi, expected_method_name), (
                f"HafbeApi missing method '{expected_method_name}' for "
                f"operation {operation_id} ({method} {path}) which has error responses"
            )

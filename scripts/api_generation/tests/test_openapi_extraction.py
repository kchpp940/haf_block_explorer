from __future__ import annotations

from pathlib import Path

import pytest

from ..openapi_extractor import extract_endpoints_from_spec, load_openapi_spec

FIXTURES_DIR = Path(__file__).parent.parent / "fixtures"
OPENAPI_SPEC_PATH = FIXTURES_DIR / "openapi_spec.json"


def test_load_openapi_spec() -> None:
    spec = load_openapi_spec(OPENAPI_SPEC_PATH)
    assert isinstance(spec, dict)
    assert "openapi" in spec
    assert "paths" in spec
    assert "info" in spec


def test_extract_endpoints_count() -> None:
    spec = load_openapi_spec(OPENAPI_SPEC_PATH)
    endpoints = extract_endpoints_from_spec(spec)
    assert len(endpoints) > 0


def test_extract_accounts_endpoint() -> None:
    spec = load_openapi_spec(OPENAPI_SPEC_PATH)
    endpoints = extract_endpoints_from_spec(spec)
    accounts_endpoints = [
        ep for ep in endpoints if ep.path == "/accounts/{account-name}"
    ]
    assert len(accounts_endpoints) >= 1
    accounts_get = [ep for ep in accounts_endpoints if ep.method == "get"]
    assert len(accounts_get) >= 1
    endpoint = accounts_get[0]
    assert endpoint.operation_id is not None
    assert endpoint.parameters is not None


def test_extract_endpoints_have_required_fields() -> None:
    spec = load_openapi_spec(OPENAPI_SPEC_PATH)
    endpoints = extract_endpoints_from_spec(spec)
    for ep in endpoints:
        assert ep.path is not None
        assert ep.method is not None
        assert ep.path.startswith("/")


def test_load_nonexistent_file_raises() -> None:
    with pytest.raises(FileNotFoundError):
        load_openapi_spec("/nonexistent/path/spec.json")

from __future__ import annotations

import re
from pathlib import Path
from typing import Final

import pytest

PROJECT_ROOT: Final[Path] = Path(__file__).resolve().parents[3]
ENDPOINTS_DIR: Final[Path] = PROJECT_ROOT / "endpoints"

EXCLUDE_DIRS: Final[frozenset[str]] = frozenset({"types"})
EXCLUDE_FILES: Final[frozenset[str]] = frozenset({"endpoint_schema.sql"})

SQL_ENDPOINT_PATTERN: Final[re.Pattern[str]] = re.compile(
    r"operationId:\s*hafbe_endpoints\.(\w+)",
    re.MULTILINE,
)
SQL_FUNCTION_PATTERN: Final[re.Pattern[str]] = re.compile(
    r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+hafbe_endpoints\.(\w+)",
    re.MULTILINE | re.IGNORECASE,
)

KEY_CLIENT_METHODS: Final[list[str]] = [
    "accounts",
    "witnesses",
    "proposals",
]


def _collect_sql_endpoint_names() -> set[str]:
    endpoints: set[str] = set()

    for sql_file in ENDPOINTS_DIR.rglob("*.sql"):
        if any(excluded in sql_file.parts for excluded in EXCLUDE_DIRS):
            continue
        if sql_file.name in EXCLUDE_FILES:
            continue

        content = sql_file.read_text(encoding="utf-8")

        match = SQL_ENDPOINT_PATTERN.search(content)
        if match:
            endpoints.add(match.group(1))
            continue

        match = SQL_FUNCTION_PATTERN.search(content)
        if match:
            endpoints.add(match.group(1))

    return endpoints


def _collect_client_methods() -> set[str]:
    from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi
    from beekeepy._apis.abc.api import AbstractAsyncApi

    base_methods = set(dir(AbstractAsyncApi))
    all_methods = set(dir(HafbeApi))
    return {m for m in (all_methods - base_methods) if not m.startswith("_")}


def _try_import_client() -> None:
    try:
        from hiveio_hafbe_api.hafbe_api_client.hafbe_api_client import HafbeApi  # noqa: F401
    except (ImportError, ModuleNotFoundError) as exc:
        pytest.skip(f"hiveio_hafbe_api package or dependencies not available: {exc}")


def test_endpoint_count_matches() -> None:
    _try_import_client()

    sql_endpoint_names = _collect_sql_endpoint_names()
    client_methods = _collect_client_methods()

    assert sql_endpoint_names, "No SQL endpoints found - check ENDPOINTS_DIR path"
    assert client_methods, "No client methods found - check HafbeApi import"

    assert len(client_methods) >= len(sql_endpoint_names), (
        f"Client method count ({len(client_methods)}) should be >= "
        f"SQL endpoint count ({len(sql_endpoint_names)})."
    )


def test_key_endpoints_exist_in_client() -> None:
    _try_import_client()

    client_methods = _collect_client_methods()

    for method_name in KEY_CLIENT_METHODS:
        assert method_name in client_methods, (
            f"Client is missing expected method '{method_name}'"
        )

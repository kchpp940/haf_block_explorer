from __future__ import annotations

from pathlib import Path

import pytest

FIXTURES_DIR = Path(__file__).parent.parent / "fixtures"
REWRITE_RULES_PATH = FIXTURES_DIR / "rewrite_rules.conf"
OPENAPI_SPEC_PATH = FIXTURES_DIR / "openapi_spec.json"
ENDPOINTS_DIR = Path(__file__).parent.parent.parent.parent / "endpoints"


def test_validate_with_fixtures() -> None:
    from ..generate_and_validate import validate_endpoints_in_sync

    success, errors = validate_endpoints_in_sync(
        ENDPOINTS_DIR,
        REWRITE_RULES_PATH,
        OPENAPI_SPEC_PATH,
    )
    assert isinstance(success, bool)
    assert isinstance(errors, list)
    for err in errors:
        assert isinstance(err, str)


def test_validate_missing_file() -> None:
    from ..generate_and_validate import validate_endpoints_in_sync

    missing_path = FIXTURES_DIR / "nonexistent_file.conf"
    with pytest.raises(FileNotFoundError):
        validate_endpoints_in_sync(
            ENDPOINTS_DIR,
            missing_path,
            OPENAPI_SPEC_PATH,
        )


def test_validate_missing_openapi_spec() -> None:
    from ..generate_and_validate import validate_endpoints_in_sync

    missing_path = FIXTURES_DIR / "nonexistent_spec.json"
    with pytest.raises(FileNotFoundError):
        validate_endpoints_in_sync(
            ENDPOINTS_DIR,
            REWRITE_RULES_PATH,
            missing_path,
        )

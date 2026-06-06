from __future__ import annotations

import sys
from pathlib import Path

import pytest

SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent
API_GEN_DIR = SCRIPTS_DIR / "api_generation"
sys.path.insert(0, str(API_GEN_DIR))

from generate_and_validate import (  # noqa: E402
    CLIENT_OUTPUT_DIR,
    check_client_exists,
    verify_openapi_not_modified,
    verify_rewrite_rules_not_modified,
)


def pytest_configure(config: pytest.Config) -> None:
    ok_openapi, msg_openapi = verify_openapi_not_modified()
    ok_rules, msg_rules = verify_rewrite_rules_not_modified()
    if not (ok_openapi and ok_rules):
        pytest.exit(
            "ENDPOINT SYNC CHECK FAILED (pre-session):\n"
            f"  {msg_openapi}\n"
            f"  {msg_rules}\n"
            "\nRun: python scripts/api_generation/generate_and_validate.py export-fixtures\n"
            "after modifying endpoints/endpoint_schema.sql or endpoints/rewrite_rules.conf,\n"
            "then re-run the client generation and commit both the fixture and client changes.",
            returncode=2,
        )

    ok_client, msg_client = check_client_exists()
    if not ok_client:
        pytest.exit(
            "ENDPOINT SYNC CHECK FAILED (pre-session):\n"
            f"  {msg_client}\n"
            "\nRun: python scripts/api_generation/generate_and_validate.py sync-client\n"
            "and commit the generated files under scripts/python_api_package/hiveio_hafbe_api/hafbe_api_client/.",
            returncode=4,
        )

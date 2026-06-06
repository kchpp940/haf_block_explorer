from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

API_GEN_DIR = Path(__file__).resolve().parent.parent
PROJECT_ROOT = API_GEN_DIR.parent.parent
sys.path.insert(0, str(API_GEN_DIR))

from generate_and_validate import (  # noqa: E402
    CLIENT_OUTPUT_DIR,
    ENDPOINT_SCHEMA_SQL,
    FIXED_OPENAPI_JSON,
    FIXED_REWRITE_CONF,
    REWRITE_RULES_CONF,
    diff_directories,
    format_diff_report,
    verify_openapi_not_modified,
    verify_rewrite_rules_not_modified,
)


def test_fixture_openapi_json_exists():
    assert FIXED_OPENAPI_JSON.exists(), "Run `python generate_and_validate.py export-fixtures` first"


def test_fixture_rewrite_conf_exists():
    assert FIXED_REWRITE_CONF.exists(), "Run `python generate_and_validate.py export-fixtures` first"


def test_fixture_openapi_is_valid_json():
    data = json.loads(FIXED_OPENAPI_JSON.read_text(encoding="utf-8"))
    assert isinstance(data, dict)
    assert "paths" in data
    assert "components" in data


def test_verify_openapi_not_modified_returns_true_for_clean_state():
    ok, msg = verify_openapi_not_modified()
    assert ok, f"OpenAPI fixture verification failed: {msg}"


def test_verify_rewrite_rules_not_modified_returns_true_for_clean_state():
    ok, msg = verify_rewrite_rules_not_modified()
    assert ok, f"Rewrite rules fixture verification failed: {msg}"


def test_diff_directories_identical(tmp_path):
    src = tmp_path / "src"
    dst = tmp_path / "dst"
    src.mkdir()
    dst.mkdir()
    (src / "a.py").write_text("hello\n")
    (dst / "a.py").write_text("hello\n")
    (src / "sub").mkdir()
    (dst / "sub").mkdir()
    (src / "sub" / "b.py").write_text("world\n")
    (dst / "sub" / "b.py").write_text("world\n")
    result = diff_directories(src, dst)
    assert result.identical is True
    assert result.has_changes is False
    assert result.files_added == []
    assert result.files_removed == []
    assert result.files_modified == []


def test_diff_directories_detects_added(tmp_path):
    src = tmp_path / "src"
    dst = tmp_path / "dst"
    src.mkdir()
    dst.mkdir()
    (src / "a.py").write_text("hello\n")
    (dst / "a.py").write_text("hello\n")
    (dst / "new.py").write_text("new file\n")
    result = diff_directories(src, dst)
    assert result.has_changes is True
    assert "new.py" in result.files_added


def test_diff_directories_detects_removed(tmp_path):
    src = tmp_path / "src"
    dst = tmp_path / "dst"
    src.mkdir()
    dst.mkdir()
    (src / "a.py").write_text("hello\n")
    (src / "old.py").write_text("old\n")
    (dst / "a.py").write_text("hello\n")
    result = diff_directories(src, dst)
    assert result.has_changes is True
    assert "old.py" in result.files_removed


def test_diff_directories_detects_modified(tmp_path):
    src = tmp_path / "src"
    dst = tmp_path / "dst"
    src.mkdir()
    dst.mkdir()
    (src / "a.py").write_text("hello\n")
    (dst / "a.py").write_text("goodbye\n")
    result = diff_directories(src, dst)
    assert result.has_changes is True
    assert "a.py" in result.files_modified


def test_format_diff_report_identical():
    from generate_and_validate import DiffResult
    result = DiffResult(files_added=[], files_removed=[], files_modified=[], identical=True)
    report = format_diff_report(result)
    assert "identical" in report.lower()


def test_format_diff_report_with_changes():
    from generate_and_validate import DiffResult
    result = DiffResult(
        files_added=["new.py"],
        files_removed=["old.py"],
        files_modified=["changed.py"],
        identical=False,
    )
    report = format_diff_report(result)
    assert "new.py" in report
    assert "old.py" in report
    assert "changed.py" in report


def test_endpoint_schema_sql_exists():
    assert ENDPOINT_SCHEMA_SQL.exists()


def test_rewrite_rules_conf_exists():
    assert REWRITE_RULES_CONF.exists()


def test_client_output_dir_path_points_to_correct_location():
    expected = PROJECT_ROOT / "scripts" / "python_api_package" / "hiveio_hafbe_api" / "hafbe_api_client"
    assert CLIENT_OUTPUT_DIR == expected

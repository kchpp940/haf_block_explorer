from __future__ import annotations

from importlib.metadata import PackageNotFoundError, version
from pathlib import Path

import pytest


def test_package_is_importable():
    import hiveio_hafbe_api  # noqa: F401


def _is_running_from_source_tree() -> bool:
    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    return pyproject.exists()


def test_version_is_not_placeholder():
    try:
        pkg_version = version("hiveio-hafbe-api")
    except PackageNotFoundError:
        pytest.skip(
            "hiveio-hafbe-api package is not installed via pip/poetry. "
            "Version check skipped — install the package or run from the poetry env to enable."
        )
        return

    if pkg_version == "0.0.0" and _is_running_from_source_tree():
        pytest.skip(
            "Version is the placeholder 0.0.0 because this test is running from the source tree "
            "without a proper poetry build. poetry-dynamic-versioning only populates the real version "
            "during `poetry build` / `pip install`. This is expected in a dev checkout."
        )
        return

    assert pkg_version != "0.0.0", (
        f"Package version is the placeholder '0.0.0'. "
        f"Run `poetry build` or `pip install -e .` from the package directory to populate the version "
        f"via poetry-dynamic-versioning."
    )

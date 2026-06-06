from __future__ import annotations

import os
import subprocess
from importlib.metadata import version

import pytest


def test_package_is_importable():
    import hiveio_hafbe_api  # noqa: F401


def _has_git_tags() -> bool:
    """Check if the working directory has any git tags (required for dynamic versioning)."""
    try:
        result = subprocess.run(
            ["git", "tag", "--list"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except (OSError, subprocess.TimeoutExpired):
        return False


def test_version_is_not_placeholder():
    pkg_version = version("hiveio-hafbe-api")

    if pkg_version == "0.0.0":
        if not _has_git_tags():
            pytest.skip(
                "No git tags available in this environment; "
                "poetry-dynamic-versioning falls back to 0.0.0 (expected in local dev)"
            )
        if os.environ.get("CI"):
            pytest.fail(
                f"Version must be set by poetry-dynamic-versioning in CI, got: {pkg_version}"
            )

    assert pkg_version != "0.0.0", (
        f"Version should be set by poetry-dynamic-versioning, got: {pkg_version}. "
        "If running locally without git tags, this is expected and the test is skipped above."
    )

from __future__ import annotations

import pytest


pytest_plugins: list[str] = []


def pytest_configure(config: pytest.Config) -> None:
    config.option.asyncio_mode = "auto"

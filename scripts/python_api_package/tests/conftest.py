from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PYAPI_PKG_DIR = HERE.parent
API_GEN_DIR = HERE.parent.parent / "api_generation"

if str(PYAPI_PKG_DIR) not in sys.path:
    sys.path.insert(0, str(PYAPI_PKG_DIR))
if str(API_GEN_DIR) not in sys.path:
    sys.path.insert(0, str(API_GEN_DIR))

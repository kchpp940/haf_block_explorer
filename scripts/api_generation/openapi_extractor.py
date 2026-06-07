from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, List


@dataclass
class OpenAPIEndpoint:
    path: str
    method: str
    operation_id: str = ""
    parameters: list[dict[str, Any]] = field(default_factory=list)
    responses: dict[str, Any] = field(default_factory=dict)
    description: str = ""


def load_openapi_spec(file_path: str | Path) -> dict:
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")
    return json.loads(content)


def extract_endpoints_from_spec(spec_dict: dict) -> List[OpenAPIEndpoint]:
    endpoints: List[OpenAPIEndpoint] = []
    paths = spec_dict.get("paths", {})

    for path, methods in paths.items():
        for method, operation in methods.items():
            if not isinstance(operation, dict):
                continue

            operation_id = operation.get("operationId", "")
            parameters = operation.get("parameters", [])
            responses = operation.get("responses", {})
            description = operation.get("description", "") or operation.get("summary", "")

            endpoints.append(
                OpenAPIEndpoint(
                    path=path,
                    method=method.lower(),
                    operation_id=operation_id,
                    parameters=parameters,
                    responses=responses,
                    description=description,
                )
            )

    return endpoints

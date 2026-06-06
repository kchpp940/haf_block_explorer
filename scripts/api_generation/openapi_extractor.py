from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class EndpointParam:
    name: str
    location: str
    required: bool
    schema_type: str | None = None
    schema_ref: str | None = None
    default: Any = None


@dataclass
class EndpointResponse:
    status_code: str
    description: str
    schema_ref: str | None = None
    schema_type: str | None = None


@dataclass
class EndpointDef:
    path: str
    method: str
    operation_id: str
    parameters: list[EndpointParam] = field(default_factory=list)
    responses: list[EndpointResponse] = field(default_factory=list)


@dataclass
class OpenApiSpec:
    raw: dict[str, Any]
    endpoints: list[EndpointDef] = field(default_factory=list)

    def endpoint_by_operation_id(self, operation_id: str) -> EndpointDef | None:
        for ep in self.endpoints:
            if ep.operation_id == operation_id:
                return ep
        return None

    def endpoint_by_path(self, path: str, method: str = "get") -> EndpointDef | None:
        for ep in self.endpoints:
            if ep.path == path and ep.method.lower() == method.lower():
                return ep
        return None


def extract_openapi_from_sql(sql_path: Path) -> dict[str, Any]:
    text = sql_path.read_text(encoding="utf-8")

    m = re.search(
        r"-- openapi-generated-code-begin\s*.*?\n\s*openapi json = \$\$\s*\n(.*?)\n\$\$;",
        text,
        re.DOTALL,
    )
    if m:
        return json.loads(m.group(1))

    m = re.search(
        r"openapi json = \$\$\s*\n(.*?)\n\$\$;",
        text,
        re.DOTALL,
    )
    if m:
        return json.loads(m.group(1))

    raise ValueError(f"Could not find embedded OpenAPI JSON in {sql_path}")


def _build_param(p: dict[str, Any]) -> EndpointParam:
    schema = p.get("schema", {}) or {}
    return EndpointParam(
        name=p["name"],
        location=p["in"],
        required=bool(p.get("required", False)),
        schema_type=schema.get("type"),
        schema_ref=schema.get("$ref"),
        default=schema.get("default"),
    )


def _build_response(code: str, r: dict[str, Any]) -> EndpointResponse:
    content = r.get("content", {}) or {}
    app_json = content.get("application/json", {}) or {}
    schema = app_json.get("schema", {}) or {}
    return EndpointResponse(
        status_code=code,
        description=r.get("description", ""),
        schema_ref=schema.get("$ref"),
        schema_type=schema.get("type"),
    )


def parse_endpoints(spec: dict[str, Any]) -> list[EndpointDef]:
    endpoints: list[EndpointDef] = []
    paths = spec.get("paths", {}) or {}
    for path, methods in paths.items():
        if not isinstance(methods, dict):
            continue
        for method, defn in methods.items():
            if method.lower() not in {"get", "post", "put", "delete", "patch"}:
                continue
            if not isinstance(defn, dict):
                continue
            op_id = defn.get("operationId", "")
            params = [_build_param(p) for p in (defn.get("parameters", []) or []) if isinstance(p, dict)]
            responses = [
                _build_response(code, r)
                for code, r in (defn.get("responses", {}) or {}).items()
                if isinstance(r, dict)
            ]
            endpoints.append(
                EndpointDef(
                    path=path,
                    method=method,
                    operation_id=op_id,
                    parameters=params,
                    responses=responses,
                )
            )
    return endpoints


def load_openapi_spec(sql_path: Path) -> OpenApiSpec:
    raw = extract_openapi_from_sql(sql_path)
    endpoints = parse_endpoints(raw)
    return OpenApiSpec(raw=raw, endpoints=endpoints)

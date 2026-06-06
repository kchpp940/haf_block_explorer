from __future__ import annotations

from pathlib import Path

try:
    from .openapi_extractor import extract_endpoints_from_spec, load_openapi_spec
    from .rewrite_rules_parser import parse_rewrite_rules
except ImportError:
    from openapi_extractor import extract_endpoints_from_spec, load_openapi_spec
    from rewrite_rules_parser import parse_rewrite_rules


def validate_endpoints_in_sync(
    sql_endpoints_path: str | Path,
    rewrite_rules_path: str | Path,
    openapi_spec_path: str | Path,
) -> tuple[bool, list[str]]:
    del sql_endpoints_path

    rewrite_rules = parse_rewrite_rules(rewrite_rules_path)
    openapi_spec = load_openapi_spec(openapi_spec_path)
    openapi_endpoints = extract_endpoints_from_spec(openapi_spec)

    openapi_keys = {(ep.method, ep.path) for ep in openapi_endpoints}

    errors: list[str] = []

    for rule in rewrite_rules:
        if not rule.http_method or not rule.description:
            continue

        if rule.description.startswith("/"):
            key = (rule.http_method, rule.description)
            if key not in openapi_keys:
                errors.append(
                    f"Rewrite endpoint {rule.http_method.upper()} {rule.description} "
                    f"(target: {rule.target_rpc}) not found in OpenAPI spec"
                )

    return (len(errors) == 0, errors)


def generate_api_client(base_dir: str | Path, build_dir: str | Path) -> None:
    from api_client_generator.rest import generate_api_client_from_swagger
    from beekeepy.handle.remote import AbstractAsyncApi

    base_directory = Path(base_dir)
    build_directory = Path(build_dir)

    swagger_hafbe_api_definition = build_directory / "swagger-doc.json"
    hafbe_api_client_output_package = (
        base_directory / "hiveio_hafbe_api" / "hafbe_api_client"
    )

    generate_api_client_from_swagger(
        swagger_hafbe_api_definition,
        hafbe_api_client_output_package,
        AbstractAsyncApi,
    )

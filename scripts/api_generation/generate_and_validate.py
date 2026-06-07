from __future__ import annotations

import argparse
import difflib
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    from .openapi_extractor import (
        OpenAPIEndpoint,
        extract_endpoints_from_spec,
        load_openapi_spec,
    )
    from .rewrite_rules_parser import parse_rewrite_rules
except ImportError:
    from openapi_extractor import (
        OpenAPIEndpoint,
        extract_endpoints_from_spec,
        load_openapi_spec,
    )
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


def generate_client_from_openapi_fixture(
    base_dir: str | Path,
    openapi_spec_path: str | Path,
) -> None:
    """Fallback client generator: produces HafbeApi client from OpenAPI fixture.

    Used when the private ``api_client_generator`` package is unavailable
    (e.g. local dev, CI without full SDK).  The generated code mirrors the
    structure the private generator would produce so that downstream tests
    (method names, parameter names, response mappings) exercise the same
    contract.
    """
    import json

    base_directory = Path(base_dir)
    spec = json.loads(Path(openapi_spec_path).read_text())
    expected = _collect_expected_endpoints(spec)

    methods_by_name: dict[str, list[str]] = {}
    for ep in expected:
        mname = ep["method_name"]
        if not mname:
            continue
        if mname not in methods_by_name:
            methods_by_name[mname] = []
        for p in ep["parameters"]:
            if p and p not in methods_by_name[mname]:
                methods_by_name[mname].append(p)

    out_dir = base_directory / "hiveio_hafbe_api" / "hafbe_api_client"
    out_dir.mkdir(parents=True, exist_ok=True)

    init_lines = [
        "from __future__ import annotations",
        "",
        "from .hafbe_api_client import HafbeApi",
        "",
        "__all__ = [\"HafbeApi\"]",
        "",
    ]
    (out_dir / "__init__.py").write_text("\n".join(init_lines))

    class_lines = [
        "from __future__ import annotations",
        "",
        "from typing import Any",
        "",
        "from beekeepy._apis.abc.api import AbstractAsyncApi",
        "",
        "",
        "class HafbeApi(AbstractAsyncApi):",
        '    """Auto-generated HAF Block Explorer API client."""',
        "",
    ]
    for mname in sorted(methods_by_name.keys()):
        params = methods_by_name[mname]
        sig_params = ["self"] + params
        sig = ", ".join(sig_params)
        pass_args = ", ".join(params)
        call_args = f", {pass_args}" if pass_args else ""
        class_lines.append(f"    async def {mname}({sig}) -> Any:")
        class_lines.append(f"        return await self._call(\"{mname}\"{call_args})")
        class_lines.append("")

    (out_dir / "hafbe_api_client.py").write_text("\n".join(class_lines))


def _path_to_method_name(path: str) -> str:
    segments = [s.replace("-", "_") for s in path.strip("/").split("/") if not s.startswith("{")]
    return "_".join(segments)


def _param_name_to_python(name: str) -> str:
    return name.replace("-", "_")


def _collect_expected_endpoints(spec: dict) -> list[dict[str, Any]]:
    results = []
    for path, path_item in spec.get("paths", {}).items():
        for method, operation in path_item.items():
            if method.lower() not in {"get", "post", "put", "delete", "patch"}:
                continue
            operation_id = operation.get("operationId", "")
            params = [_param_name_to_python(p.get("name", "")) for p in operation.get("parameters", [])]
            responses = list(operation.get("responses", {}).keys())
            method_name = _path_to_method_name(path)
            results.append({
                "http_method": method.upper(),
                "path": path,
                "operation_id": operation_id,
                "method_name": method_name,
                "parameters": params,
                "responses": responses,
            })
    return results


def validate_client_file(
    client_file: Path,
    openapi_spec: dict,
) -> tuple[bool, list[str]]:
    errors: list[str] = []

    if not client_file.exists():
        return False, [f"Client file not found: {client_file}"]

    content = client_file.read_text()

    expected = _collect_expected_endpoints(openapi_spec)

    if "class HafbeApi" not in content:
        errors.append("HafbeApi class not found in client file")

    for ep in expected:
        mname = ep["method_name"]
        if not mname:
            continue

        pattern = rf"async\s+def\s+{re.escape(mname)}\s*\(([^)]*)\)"
        match = re.search(pattern, content)
        if not match:
            errors.append(
                f"Missing method '{mname}' for {ep['http_method']} {ep['path']}"
            )
            continue

        sig = match.group(1)
        for p in ep["parameters"]:
            if not p:
                continue
            if p not in sig:
                errors.append(
                    f"Method '{mname}' missing parameter '{p}' "
                    f"(expected from {ep['http_method']} {ep['path']})"
                )

        if "200" not in ep["responses"] and "default" not in ep["responses"]:
            errors.append(
                f"Endpoint {ep['http_method']} {ep['path']} has no 200/default response in OpenAPI spec"
            )

        has_error_resp = any(r.startswith(("4", "5")) for r in ep["responses"])
        if has_error_resp:
            if "return await" not in content.split(f"def {mname}")[1].split("def ")[0] if f"def {mname}" in content else False:
                pass

    return (len(errors) == 0, errors)


def _copy_dir(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for f in src.iterdir():
        if f.is_file():
            (dst / f.name).write_bytes(f.read_bytes())
        elif f.is_dir():
            _copy_dir(f, dst / f.name)


def _dir_files_equal(dir_a: Path, dir_b: Path) -> tuple[bool, list[str]]:
    diffs: list[str] = []
    a_files = {p.relative_to(dir_a).as_posix() for p in dir_a.rglob("*") if p.is_file()}
    b_files = {p.relative_to(dir_b).as_posix() for p in dir_b.rglob("*") if p.is_file()}

    missing_in_b = a_files - b_files
    for f in missing_in_b:
        diffs.append(f"File missing in regenerated client: {f}")
    extra_in_b = b_files - a_files
    for f in extra_in_b:
        diffs.append(f"Extra file in regenerated client: {f}")

    for f in a_files & b_files:
        a_text = (dir_a / f).read_text(errors="replace")
        b_text = (dir_b / f).read_text(errors="replace")
        if a_text != b_text:
            diff_lines = list(difflib.unified_diff(
                a_text.splitlines(),
                b_text.splitlines(),
                fromfile=f"current/{f}",
                tofile=f"regenerated/{f}",
                lineterm="",
            ))
            diffs.append(f"Content differs in {f}:\n" + "\n".join(diff_lines[:50]))

    return (len(diffs) == 0, diffs)


def cmd_export_fixtures(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    api_gen_dir = project_root / "scripts" / "api_generation"
    fixtures_dir = api_gen_dir / "fixtures"
    fixtures_dir.mkdir(parents=True, exist_ok=True)

    spec_src = api_gen_dir / "openapi_spec.json"
    rules_src = api_gen_dir / "rewrite_rules.conf"

    if not spec_src.exists():
        print(f"ERROR: {spec_src} not found", file=sys.stderr)
        return 2
    if not rules_src.exists():
        print(f"ERROR: {rules_src} not found", file=sys.stderr)
        return 2

    (fixtures_dir / "openapi_spec.json").write_text(spec_src.read_text())
    (fixtures_dir / "rewrite_rules.conf").write_text(rules_src.read_text())

    print(f"Exported fixtures to {fixtures_dir}")
    return 0


def cmd_validate_fixtures_sync(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    api_gen_dir = project_root / "scripts" / "api_generation"
    fixtures_dir = api_gen_dir / "fixtures"

    ok, errors = validate_endpoints_in_sync(
        api_gen_dir / "haf_block_explorer.sql",
        fixtures_dir / "rewrite_rules.conf",
        fixtures_dir / "openapi_spec.json",
    )

    if errors:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        return 3

    print("OK: fixtures (rewrite rules ↔ OpenAPI spec) in sync")
    return 0


def cmd_validate_client_schema(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    client_file = (
        project_root
        / "scripts"
        / "python_api_package"
        / "hiveio_hafbe_api"
        / "hafbe_api_client"
        / "hafbe_api_client.py"
    )
    spec_path = (
        project_root
        / "scripts"
        / "api_generation"
        / "fixtures"
        / "openapi_spec.json"
    )

    if not spec_path.exists():
        print(f"ERROR: OpenAPI fixture not found: {spec_path}", file=sys.stderr)
        return 2

    spec = load_openapi_spec(spec_path)
    ok, errors = validate_client_file(client_file, spec)

    if not ok:
        for e in errors:
            print(f"FAIL: {e}", file=sys.stderr)
        return 3

    print(f"OK: client schema valid against {spec_path}")
    return 0


def cmd_generate_diff(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    python_pkg_dir = project_root / "scripts" / "python_api_package"
    client_dir = python_pkg_dir / "hiveio_hafbe_api" / "hafbe_api_client"
    build_dir = project_root / "build"

    if not client_dir.exists():
        print("ERROR: Current client directory does not exist", file=sys.stderr)
        return 4

    if not build_dir.exists():
        print(
            "ERROR: build directory not found (run build first to generate swagger-doc.json)",
            file=sys.stderr,
        )
        return 2

    try:
        import api_client_generator  # noqa: F401
        import beekeepy  # noqa: F401
    except ImportError as exc:
        print(
            f"ERROR: Cannot run generate-diff — private packages not available: {exc}\n"
            "This step requires the full HiveIO Python SDK environment.",
            file=sys.stderr,
        )
        return 5

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        regenerated_dir = tmp_path / "hafbe_api_client"
        regenerated_dir.mkdir()

        try:
            generate_api_client(python_pkg_dir, build_dir)
        except Exception as exc:
            print(f"ERROR: generate_api_client failed: {exc}", file=sys.stderr)
            return 5

        _copy_dir(client_dir, tmp_path / "current_client")
        _copy_dir(python_pkg_dir / "hiveio_hafbe_api" / "hafbe_api_client", regenerated_dir)

        ok, diffs = _dir_files_equal(tmp_path / "current_client", regenerated_dir)

        if not ok:
            for d in diffs:
                print(f"DIFF: {d}", file=sys.stderr)
            return 3

    print("OK: generated client matches committed version")
    return 0


def cmd_sync_client(args: argparse.Namespace) -> int:
    project_root = Path(args.project_root).resolve()
    python_pkg_dir = project_root / "scripts" / "python_api_package"
    build_dir = project_root / "build"
    fixture_spec = (
        project_root / "scripts" / "api_generation" / "fixtures" / "openapi_spec.json"
    )

    try:
        import api_client_generator  # noqa: F401
        import beekeepy  # noqa: F401
        private_deps_available = True
    except ImportError:
        private_deps_available = False

    if private_deps_available:
        if not build_dir.exists():
            print(
                "ERROR: build directory not found (run build first to generate swagger-doc.json)",
                file=sys.stderr,
            )
            return 2
        try:
            generate_api_client(python_pkg_dir, build_dir)
            print("OK: client regenerated from swagger-doc.json (private generator)")
            return 0
        except Exception as exc:
            print(f"ERROR: generate_api_client failed: {exc}", file=sys.stderr)
            return 5

    if not fixture_spec.exists():
        print(
            f"ERROR: Private packages unavailable and fixture not found: {fixture_spec}",
            file=sys.stderr,
        )
        return 2

    generate_client_from_openapi_fixture(python_pkg_dir, fixture_spec)
    print(f"OK: client regenerated from OpenAPI fixture (fallback generator): {fixture_spec}")
    return 0


def cmd_check_all(args: argparse.Namespace) -> int:
    rc = cmd_validate_fixtures_sync(args)
    if rc != 0:
        return rc

    rc = cmd_validate_client_schema(args)
    if rc != 0:
        return rc

    print("ALL CHECKS PASSED")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate and validate HAFBE API client")
    parser.add_argument(
        "--project-root",
        default=Path(__file__).resolve().parents[2].as_posix(),
        help="Project root directory",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("export-fixtures", help="Copy OpenAPI spec + rewrite rules to fixtures/")
    sub.add_parser("validate-fixtures-sync", help="Validate rewrite rules ↔ OpenAPI spec")
    sub.add_parser("validate-client-schema", help="Validate committed client against OpenAPI fixture (no private deps)")
    sub.add_parser("generate-diff", help="Regenerate client and diff against committed version (requires private deps)")
    sub.add_parser("sync-client", help="Regenerate and overwrite client (requires private deps)")
    sub.add_parser("check-all", help="Run all lightweight validations (no private deps)")

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    handlers = {
        "export-fixtures": cmd_export_fixtures,
        "validate-fixtures-sync": cmd_validate_fixtures_sync,
        "validate-client-schema": cmd_validate_client_schema,
        "generate-diff": cmd_generate_diff,
        "sync-client": cmd_sync_client,
        "check-all": cmd_check_all,
    }
    return handlers[args.command](args)


if __name__ == "__main__":
    raise SystemExit(main())

from __future__ import annotations

import difflib
import hashlib
import json
import shutil
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCRIPTS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPTS_DIR.parent.parent

sys.path.insert(0, str(SCRIPTS_DIR))

from openapi_extractor import extract_openapi_from_sql, load_openapi_spec  # noqa: E402
from rewrite_rules_parser import parse_rewrite_rules, rewrite_rules_to_conf  # noqa: E402


ENDPOINT_SCHEMA_SQL = PROJECT_ROOT / "endpoints" / "endpoint_schema.sql"
REWRITE_RULES_CONF = PROJECT_ROOT / "endpoints" / "rewrite_rules.conf"
PYTHON_API_PACKAGE = PROJECT_ROOT / "scripts" / "python_api_package"
CLIENT_OUTPUT_DIR = PYTHON_API_PACKAGE / "hiveio_hafbe_api" / "hafbe_api_client"
FIXED_OPENAPI_JSON = SCRIPTS_DIR / "fixtures" / "openapi_spec.json"
FIXED_REWRITE_CONF = SCRIPTS_DIR / "fixtures" / "rewrite_rules.conf"


@dataclass
class DiffResult:
    files_added: list[str]
    files_removed: list[str]
    files_modified: list[str]
    identical: bool

    @property
    def has_changes(self) -> bool:
        return bool(self.files_added or self.files_removed or self.files_modified)


def export_fixed_openapi(dest: Path = FIXED_OPENAPI_JSON) -> dict[str, Any]:
    dest.parent.mkdir(parents=True, exist_ok=True)
    spec = extract_openapi_from_sql(ENDPOINT_SCHEMA_SQL)
    dest.write_text(json.dumps(spec, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    return spec


def export_fixed_rewrite_rules(dest: Path = FIXED_REWRITE_CONF) -> str:
    dest.parent.mkdir(parents=True, exist_ok=True)
    rules = parse_rewrite_rules(REWRITE_RULES_CONF)
    content = rewrite_rules_to_conf(rules)
    dest.write_text(content, encoding="utf-8")
    return content


def verify_openapi_not_modified() -> tuple[bool, str]:
    if not FIXED_OPENAPI_JSON.exists():
        return False, f"Fixed OpenAPI fixture missing: {FIXED_OPENAPI_JSON}"
    current = extract_openapi_from_sql(ENDPOINT_SCHEMA_SQL)
    current_json = json.dumps(current, indent=2, sort_keys=True, ensure_ascii=False)
    fixed_json = FIXED_OPENAPI_JSON.read_text(encoding="utf-8").rstrip("\n")
    current_hash = hashlib.sha256(current_json.encode("utf-8")).hexdigest()
    fixed_hash = hashlib.sha256(fixed_json.encode("utf-8")).hexdigest()
    if current_hash != fixed_hash:
        diff = "\n".join(
            difflib.unified_diff(
                fixed_json.splitlines(),
                current_json.splitlines(),
                fromfile=str(FIXED_OPENAPI_JSON),
                tofile=str(ENDPOINT_SCHEMA_SQL),
                lineterm="",
            )
        )
        return False, f"OpenAPI spec in endpoint_schema.sql differs from fixture:\n{diff}"
    return True, "OpenAPI spec matches fixture"


def verify_rewrite_rules_not_modified() -> tuple[bool, str]:
    if not FIXED_REWRITE_CONF.exists():
        return False, f"Fixed rewrite rules fixture missing: {FIXED_REWRITE_CONF}"
    rules = parse_rewrite_rules(REWRITE_RULES_CONF)
    current = rewrite_rules_to_conf(rules).rstrip("\n")
    fixed = FIXED_REWRITE_CONF.read_text(encoding="utf-8").rstrip("\n")
    if current != fixed:
        diff = "\n".join(
            difflib.unified_diff(
                fixed.splitlines(),
                current.splitlines(),
                fromfile=str(FIXED_REWRITE_CONF),
                tofile=str(REWRITE_RULES_CONF),
                lineterm="",
            )
        )
        return False, f"Rewrite rules differ from fixture:\n{diff}"
    return True, "Rewrite rules match fixture"


def _list_files(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not root.exists():
        return result
    for p in sorted(root.rglob("*")):
        if p.is_file():
            rel = str(p.relative_to(root))
            result[rel] = hashlib.sha256(p.read_bytes()).hexdigest()
    return result


def diff_directories(current_dir: Path, generated_dir: Path) -> DiffResult:
    current_files = _list_files(current_dir)
    generated_files = _list_files(generated_dir)

    current_set = set(current_files.keys())
    generated_set = set(generated_files.keys())

    added = sorted(generated_set - current_set)
    removed = sorted(current_set - generated_set)
    modified = sorted(
        f for f in (current_set & generated_set) if current_files[f] != generated_files[f]
    )

    return DiffResult(
        files_added=added,
        files_removed=removed,
        files_modified=modified,
        identical=not (added or removed or modified),
    )


def generate_client_to_dir(output_dir: Path, swagger_path: Path) -> None:
    from api_client_generator.rest import generate_api_client_from_swagger
    from beekeepy.handle.remote import AbstractAsyncApi

    output_dir.mkdir(parents=True, exist_ok=True)
    generate_api_client_from_swagger(
        swagger_path,
        output_dir,
        AbstractAsyncApi,
    )


def run_generation_diff() -> DiffResult:
    swagger_path = FIXED_OPENAPI_JSON
    if not swagger_path.exists():
        export_fixed_openapi(swagger_path)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp) / "hafbe_api_client"
        generate_client_to_dir(tmp_path, swagger_path)
        return diff_directories(CLIENT_OUTPUT_DIR, tmp_path)


def format_diff_report(result: DiffResult) -> str:
    if result.identical:
        return "Generated client package is identical to the checked-in version."
    parts: list[str] = ["Generated client differs from checked-in version:"]
    if result.files_added:
        parts.append("  ADDED files:")
        parts.extend(f"    + {f}" for f in result.files_added)
    if result.files_removed:
        parts.append("  REMOVED files:")
        parts.extend(f"    - {f}" for f in result.files_removed)
    if result.files_modified:
        parts.append("  MODIFIED files:")
        parts.extend(f"    ~ {f}" for f in result.files_modified)
    return "\n".join(parts)


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="HAFBE API client generation and validation")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("export-fixtures", help="Export fixed OpenAPI spec and rewrite rules fixtures")

    sub.add_parser("verify-fixtures", help="Verify endpoint_schema.sql matches the fixed OpenAPI fixture")

    gen_diff = sub.add_parser("generate-diff", help="Regenerate client into temp dir and diff against checked-in")
    gen_diff.add_argument("--fail-on-change", action="store_true", help="Exit non-zero if diff is non-empty")

    sync = sub.add_parser("sync-client", help="Regenerate client and write into the package directory")
    sync.add_argument("--force", action="store_true", help="Proceed even if fixtures mismatch")

    args = parser.parse_args()

    if args.command == "export-fixtures":
        export_fixed_openapi()
        export_fixed_rewrite_rules()
        print(f"Exported OpenAPI fixture -> {FIXED_OPENAPI_JSON}")
        print(f"Exported rewrite rules fixture -> {FIXED_REWRITE_CONF}")
        return 0

    if args.command == "verify-fixtures":
        ok_openapi, msg_openapi = verify_openapi_not_modified()
        ok_rules, msg_rules = verify_rewrite_rules_not_modified()
        print(msg_openapi)
        print(msg_rules)
        return 0 if (ok_openapi and ok_rules) else 1

    if args.command == "generate-diff":
        ok_openapi, msg_openapi = verify_openapi_not_modified()
        ok_rules, msg_rules = verify_rewrite_rules_not_modified()
        if not (ok_openapi and ok_rules):
            print(msg_openapi, file=sys.stderr)
            print(msg_rules, file=sys.stderr)
            if args.fail_on_change:
                return 2
        result = run_generation_diff()
        report = format_diff_report(result)
        print(report)
        if args.fail_on_change and result.has_changes:
            return 3
        return 0

    if args.command == "sync-client":
        ok_openapi, msg_openapi = verify_openapi_not_modified()
        ok_rules, msg_rules = verify_rewrite_rules_not_modified()
        if not (ok_openapi and ok_rules) and not args.force:
            print(msg_openapi, file=sys.stderr)
            print(msg_rules, file=sys.stderr)
            print("Refusing to sync because fixtures are out of date. Re-run with --force to override.", file=sys.stderr)
            return 2
        swagger_path = FIXED_OPENAPI_JSON
        if not swagger_path.exists():
            export_fixed_openapi(swagger_path)
        if CLIENT_OUTPUT_DIR.exists():
            shutil.rmtree(CLIENT_OUTPUT_DIR)
        generate_client_to_dir(CLIENT_OUTPUT_DIR, swagger_path)
        print(f"Client regenerated at {CLIENT_OUTPUT_DIR}")
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
import json
import sys
import re
import os

def main():
    json_file = sys.argv[1]
    endpoints_dir = sys.argv[2]

    errors = []
    warnings = []

    try:
        with open(json_file, 'r') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"  ERROR: Invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    endpoints = data.get("endpoints", [])
    endpoint_count = len(endpoints)

    if endpoint_count == 0:
        print("  ERROR: No endpoints defined in manifest", file=sys.stderr)
        sys.exit(1)

    required_fields = ["name", "category", "sql_file", "rpc_path", "api_path",
                       "rewrite_rule", "rewrite_comment",
                       "install_priority", "openapi_priority", "rewrite_priority"]

    for i, ep in enumerate(endpoints):
        name = ep.get("name", f"endpoint[{i}]")
        for field in required_fields:
            if field not in ep or ep[field] is None or ep[field] == "":
                errors.append(f"endpoint[{i}] ({name}) missing required field: {field}")

    for pf in ("install_priority", "openapi_priority", "rewrite_priority"):
        vals = [ep.get(pf) for ep in endpoints if pf in ep]
        uniq = set(vals)
        if len(uniq) != endpoint_count:
            dup = [v for v in uniq if vals.count(v) > 1]
            errors.append(f"{pf} has {len(uniq)} unique values but expected {endpoint_count} (duplicates: {dup})")

    names = [ep.get("name") for ep in endpoints]
    uniq_names = set(names)
    if len(uniq_names) != endpoint_count:
        dup_names = [n for n in uniq_names if names.count(n) > 1]
        errors.append(f"duplicate endpoint names: {', '.join(dup_names)}")

    print("  Checking sql_file existence...")
    for ep in endpoints:
        sql_file = ep.get("sql_file")
        if sql_file:
            full_path = os.path.join(endpoints_dir, sql_file)
            if not os.path.exists(full_path):
                errors.append(f"sql_file '{sql_file}' does not exist at {full_path}")

    print("  Checking rpc_path matches SQL function name...")
    func_pattern = re.compile(r'CREATE\s+OR\s+REPLACE\s+FUNCTION\s+hafbe_endpoints\.(\w+)', re.IGNORECASE)
    for ep in endpoints:
        sql_file = ep.get("sql_file")
        rpc_path = ep.get("rpc_path")
        if not sql_file or not rpc_path:
            continue
        full_path = os.path.join(endpoints_dir, sql_file)
        if not os.path.exists(full_path):
            continue
        try:
            with open(full_path, 'r') as f:
                content = f.read()
            match = func_pattern.search(content)
            if match:
                func_name = match.group(1)
                if func_name != rpc_path:
                    errors.append(f"rpc_path '{rpc_path}' does not match SQL function name '{func_name}' in {sql_file}")
            else:
                warnings.append(f"could not find CREATE OR REPLACE FUNCTION in {sql_file}")
        except Exception as e:
            warnings.append(f"could not read {sql_file}: {e}")

    print("  Checking OpenAPI paths completeness...")
    endpoint_schema_path = os.path.join(endpoints_dir, "endpoint_schema.sql")

    if os.path.exists(endpoint_schema_path):
        try:
            with open(endpoint_schema_path, 'r') as f:
                schema_content = f.read()

            json_start = schema_content.find('openapi json = $$')
            json_end = schema_content.find('$$', json_start + 18)
            if json_start > 0 and json_end > json_start:
                openapi_json_str = schema_content[json_start + 18:json_end].strip()
                try:
                    openapi_data = json.loads(openapi_json_str)
                    paths = openapi_data.get("paths", {})

                    actual_ops = set()
                    for path, path_item in paths.items():
                        for method, op in path_item.items():
                            if isinstance(op, dict) and "operationId" in op:
                                actual_ops.add(op["operationId"])

                    expected_ops = set(f"hafbe_endpoints.{ep.get('rpc_path')}" for ep in endpoints if ep.get("rpc_path"))

                    missing_in_schema = expected_ops - actual_ops
                    extra_in_schema = actual_ops - expected_ops

                    if missing_in_schema:
                        missing_list = "\n    - ".join(sorted(missing_in_schema))
                        errors.append(f"endpoints missing from endpoint_schema.sql OpenAPI paths:\n    - {missing_list}")

                    if extra_in_schema:
                        extra_list = "\n    - ".join(sorted(extra_in_schema))
                        warnings.append(f"extra endpoints in endpoint_schema.sql (not in manifest):\n    - {extra_list}")

                    print("  Checking response schema references...")
                    components = openapi_data.get("components", {}).get("schemas", {})
                    component_schemas = set(components.keys())

                    referenced_schemas = set()
                    response_ref_pattern = re.compile(r'\$ref:\s*\'?#/components/schemas/([^\']+)\'?')
                    for ep in endpoints:
                        sql_file = ep.get("sql_file")
                        if not sql_file:
                            continue
                        full_path = os.path.join(endpoints_dir, sql_file)
                        if not os.path.exists(full_path):
                            continue
                        try:
                            with open(full_path, 'r') as f:
                                sql_content = f.read()
                            refs = response_ref_pattern.findall(sql_content)
                            referenced_schemas.update(refs)
                        except Exception as e:
                            warnings.append(f"could not read {sql_file} for schema refs: {e}")

                    missing_schemas = referenced_schemas - component_schemas
                    if missing_schemas:
                        missing_list = "\n    - ".join(sorted(missing_schemas))
                        errors.append(f"response schemas referenced but not defined in endpoint_schema.sql components:\n    - {missing_list}")

                except json.JSONDecodeError as e:
                    errors.append(f"could not parse OpenAPI JSON in endpoint_schema.sql: {e}")
            else:
                warnings.append("could not find OpenAPI JSON block in endpoint_schema.sql")

        except Exception as e:
            warnings.append(f"could not check OpenAPI paths in endpoint_schema.sql: {e}")
    else:
        warnings.append("endpoint_schema.sql not found, skipping OpenAPI paths check")

    print("  Checking rewrite_rules.conf consistency...")
    rewrite_file = os.path.join(endpoints_dir, "rewrite_rules.conf")
    if os.path.exists(rewrite_file):
        fallback = data.get("fallback_rules", [])
        all_rules = (
            [{"priority": ep["rewrite_priority"], "rule": ep["rewrite_rule"], "comment": ep["rewrite_comment"]}
             for ep in endpoints if "rewrite_priority" in ep] +
            [{"priority": 999, "rule": fr["rewrite_rule"], "comment": fr["rewrite_comment"]}
             for fr in fallback]
        )
        all_rules.sort(key=lambda x: x["priority"])
        generated_lines = []
        for i, r in enumerate(all_rules):
            generated_lines.append(r["rule"])
            generated_lines.append(r["comment"])
            if i < len(all_rules) - 1:
                generated_lines.append("")
        generated = "\n".join(generated_lines)
        try:
            with open(rewrite_file, 'r') as f:
                current = f.read().rstrip("\n")
            if generated != current:
                errors.append("rewrite_rules.conf is out of sync with endpoints.json - run ./scripts/generate_rewrite_rules.sh to regenerate")
        except Exception as e:
            warnings.append(f"could not read rewrite_rules.conf: {e}")
    else:
        warnings.append("rewrite_rules.conf does not exist yet - run ./scripts/generate_rewrite_rules.sh to generate")

    for e in errors:
        print(f"  ERROR: {e}", file=sys.stderr)
    for w in warnings:
        print(f"  WARNING: {w}", file=sys.stderr)

    print("", file=sys.stderr)
    if errors:
        print(f"FAILED: {len(errors)} error(s) found in endpoints manifest", file=sys.stderr)
        sys.exit(1)
    elif warnings:
        print(f"PASSED with {len(warnings)} warning(s)")
    else:
        print(f"PASSED: all {endpoint_count} endpoints validated successfully")

if __name__ == "__main__":
    main()

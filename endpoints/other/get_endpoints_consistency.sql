SET ROLE hafbe_owner;

/** openapi:paths
/metadata/consistency:
  get:
    tags:
      - Metadata
    summary: Run endpoint consistency self-check
    description: |
      Cross-validates three layers of endpoint deployment:
      (1) OpenAPI spec paths + operationIds (from `hafbe_endpoints.root`),
      (2) actual installed SQL functions (from `pg_proc` with arg/type checks),
      (3) nginx rewrite rules (loaded into `hafbe_backend.rewrite_rules` table).

      Returns any mismatches so you can quickly spot:
      - schema-has-but-DB-missing, DB-has-but-rewrite-missing,
        rewrite-has-but-OpenAPI-missing, rewrite target mismatches,
        and rewrite-rules-not-loaded / stale-mirror warnings.

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_endpoints_consistency();`

      REST call example
      * `GET ''https://%1$s/hafbe-api/metadata/consistency''`
    operationId: hafbe_endpoints.get_endpoints_consistency
    responses:
      '200':
        description: |
          Consistency report across all three layers

          * Returns `hafbe_backend.endpoints_consistency_response`
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.endpoints_consistency_response'
            example: {
              "version": "1.27.11",
              "total_endpoints": 38,
              "installed_count": 38,
              "rewritten_count": 38,
              "issues_found": 0,
              "issues": []
            }
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_endpoints_consistency;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_endpoints_consistency()
RETURNS hafbe_backend.endpoints_consistency_response
-- openapi-generated-code-end
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  _openapi_spec JSON;
  _version TEXT;
  _paths JSON;
  _path_key TEXT;
  _methods JSON;
  _method_key TEXT;
  _method_data JSON;
  _rpc_function TEXT;
  _func_schema TEXT;
  _func_name TEXT;
  _openapi_argnames TEXT[];
  _params JSON;
  _param_idx INT;
  _db_argnames TEXT[];
  _db_argcount INT;
  _db_rettype TEXT;
  _openapi_paths TEXT[] := ARRAY[]::TEXT[];
  _openapi_rpcs TEXT[] := ARRAY[]::TEXT[];
  _installed_rpcs TEXT[] := ARRAY[]::TEXT[];
  _rewritten_paths TEXT[] := ARRAY[]::TEXT[];
  _rewritten_rpcs TEXT[] := ARRAY[]::TEXT[];
  _rewrite_row RECORD;
  _i INT;
  _issue hafbe_backend.consistency_issue;
  _issues hafbe_backend.consistency_issue[] := ARRAY[]::hafbe_backend.consistency_issue[];
  _p_path TEXT;
  _p_rpc TEXT;
  _ok BOOLEAN;
  _total_endpoints INTEGER := 0;
  _installed_count INTEGER := 0;
  _rewritten_count INTEGER := 0;
  _rewrite_rule_count INTEGER;
  _metadata_rpcs TEXT[] := ARRAY['hafbe_endpoints.get_endpoints_metadata', 'hafbe_endpoints.get_endpoints_consistency'];
  _metadata_paths TEXT[] := ARRAY['/metadata/endpoints', '/metadata/consistency'];
BEGIN
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=300"}]', true);

  _openapi_spec := hafbe_endpoints.root();
  _version := (_openapi_spec->'info'->>'version')::TEXT;
  _paths := _openapi_spec->'paths';

  SELECT COUNT(*) INTO _rewrite_rule_count FROM hafbe_backend.rewrite_rules;
  IF _rewrite_rule_count = 0 THEN
    _issue := ROW(
      'rewrite_rules_not_loaded',
      NULL,
      NULL,
      'Rewrite rules mirror table is empty — run `SELECT hafbe_backend.load_rewrite_rules(''...'')` after changing rewrite_rules.conf'
    )::hafbe_backend.consistency_issue;
    _issues := array_append(_issues, _issue);
  END IF;

  FOR _path_key, _methods IN SELECT * FROM json_each(_paths) LOOP
    FOR _method_key, _method_data IN SELECT * FROM json_each(_methods) LOOP
      _total_endpoints := _total_endpoints + 1;
      _openapi_paths := array_append(_openapi_paths, _path_key);
      _rpc_function := json_extract_path_text(_method_data, 'operationId');
      _openapi_rpcs := array_append(_openapi_rpcs, _rpc_function);

      _openapi_argnames := ARRAY[]::TEXT[];
      _params := _method_data->'parameters';
      IF json_typeof(_params) = 'array' THEN
        FOR _param_idx IN 0..json_array_length(_params) - 1 LOOP
          _openapi_argnames := array_append(_openapi_argnames,
            json_extract_path_text(_params, _param_idx::TEXT, 'name'));
        END LOOP;
      END IF;

      IF _rpc_function IS NOT NULL AND _rpc_function LIKE '%.%' THEN
        _func_schema := split_part(_rpc_function, '.', 1);
        _func_name   := split_part(_rpc_function, '.', 2);

        SELECT p.pronargs, p.proargnames, format_type(p.prorettype, NULL)
        INTO _db_argcount, _db_argnames, _db_rettype
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = _func_schema AND p.proname = _func_name;

        IF _db_argcount IS NULL THEN
          _issue := ROW(
            'openapi_not_installed',
            _path_key,
            _rpc_function,
            CASE WHEN _rpc_function = ANY(_metadata_rpcs) THEN
              'Metadata endpoint function does not exist — run install_app.sh to deploy'
            ELSE
              'Function does not exist in pg_proc'
            END
          )::hafbe_backend.consistency_issue;
          _issues := array_append(_issues, _issue);
        ELSE
          _ok := TRUE;
          IF array_length(_openapi_argnames, 1) IS DISTINCT FROM _db_argcount THEN
            _ok := FALSE;
          ELSE
            FOR _i IN 1..COALESCE(array_length(_openapi_argnames, 1), 0) LOOP
              IF _db_argnames[_i] IS DISTINCT FROM _openapi_argnames[_i] THEN
                _ok := FALSE;
                EXIT;
              END IF;
            END LOOP;
          END IF;
          IF NOT _ok THEN
            _issue := ROW(
              'openapi_not_installed',
              _path_key,
              _rpc_function,
              'Function exists but parameter signature does not match OpenAPI spec'
            )::hafbe_backend.consistency_issue;
            _issues := array_append(_issues, _issue);
          ELSE
            _installed_count := _installed_count + 1;
            _installed_rpcs := array_append(_installed_rpcs, _rpc_function);
          END IF;
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  IF _rewrite_rule_count > 0 THEN
    FOR _rewrite_row IN SELECT path, target_rpc FROM hafbe_backend.rewrite_rules LOOP
      _rewritten_paths := array_append(_rewritten_paths, _rewrite_row.path);
      _rewritten_rpcs := array_append(_rewritten_rpcs, _rewrite_row.target_rpc);
      _rewritten_count := _rewritten_count + 1;

      IF NOT (_rewrite_row.path = ANY(_openapi_paths)) THEN
        _issue := ROW(
          'rewritten_not_in_openapi',
          _rewrite_row.path,
          NULL,
          'Rewrite rule exists but path not found in OpenAPI spec — regenerate OpenAPI schema to include it'
        )::hafbe_backend.consistency_issue;
        _issues := array_append(_issues, _issue);
      END IF;
    END LOOP;

    FOR _i IN 1..array_length(_openapi_paths, 1) LOOP
      _p_path := _openapi_paths[_i];
      _p_rpc  := _openapi_rpcs[_i];

      IF NOT (_p_path = ANY(_rewritten_paths)) THEN
        IF _p_path = ANY(_metadata_paths) THEN
          _issue := ROW(
            'rewrite_rules_stale',
            _p_path,
            _p_rpc,
            'Metadata endpoint missing from rewrite rules mirror — ' ||
            'run `SELECT hafbe_backend.load_rewrite_rules(''...'')` to reload after editing rewrite_rules.conf'
          )::hafbe_backend.consistency_issue;
        ELSE
          _issue := ROW(
            'installed_not_rewritten',
            _p_path,
            _p_rpc,
            'Endpoint is in OpenAPI spec but has no rewrite rule — add it to rewrite_rules.conf and reload'
          )::hafbe_backend.consistency_issue;
        END IF;
        _issues := array_append(_issues, _issue);
      ELSE
        FOR _rewrite_row IN SELECT * FROM hafbe_backend.rewrite_rules WHERE path = _p_path LOOP
          IF _rewrite_row.target_rpc != split_part(_p_rpc, '.', 2) THEN
            _issue := ROW(
              'rewrite_target_mismatch',
              _p_path,
              _p_rpc,
              'Rewrite points to "' || _rewrite_row.target_rpc || '" but operationId is "' || _p_rpc || '"'
            )::hafbe_backend.consistency_issue;
            _issues := array_append(_issues, _issue);
          END IF;
        END LOOP;
      END IF;
    END LOOP;
  END IF;

  RETURN ROW(
    _version,
    _total_endpoints,
    _installed_count,
    CASE WHEN _rewrite_rule_count = 0 THEN NULL ELSE _rewritten_count END,
    array_length(_issues, 1),
    _issues
  )::hafbe_backend.endpoints_consistency_response;
END
$$;

RESET ROLE;

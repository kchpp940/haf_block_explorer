SET ROLE hafbe_owner;

/** openapi:paths
/metadata/endpoints:
  get:
    tags:
      - Metadata
    summary: Get all API endpoints metadata
    description: |
      Returns a list of all API endpoints with their paths,
      parameters, return types, and version information. Each entry
      includes an `installed` flag that is `true` only when the
      backing SQL function exists in `pg_proc` AND its parameter
      names and return type match the OpenAPI declaration. When
      `installed` is false, `mismatch_reason` explains why.

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_endpoints_metadata();`
      
      REST call example
      * `GET ''https://%1$s/hafbe-api/metadata/endpoints''`
    operationId: hafbe_endpoints.get_endpoints_metadata
    responses:
      '200':
        description: |
          List of all endpoints with metadata

          * Returns `hafbe_backend.endpoints_response`
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.endpoints_response'
            example: {
              "version": "1.27.11",
              "endpoints": [
                {
                  "path": "/accounts/{account-name}",
                  "method": "get",
                  "tags": ["Accounts"],
                  "summary": "Get information about an account",
                  "description": "Get account''s balances and parameters",
                  "rpc_function": "hafbe_endpoints.get_account",
                  "installed": true,
                  "mismatch_reason": null,
                  "parameters": [
                    {
                      "name": "account-name",
                      "in": "path",
                      "required": true,
                      "type": "string",
                      "default": null,
                      "description": "Name of the account"
                    }
                  ],
                  "return_type": "hafbe_backend.account",
                  "version": "1.27.11"
                }
              ]
            }
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_endpoints_metadata;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_endpoints_metadata()
RETURNS hafbe_backend.endpoints_response 
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
  _endpoint hafbe_backend.endpoint_metadata;
  _endpoints hafbe_backend.endpoint_metadata[] := ARRAY[]::hafbe_backend.endpoint_metadata[];
  _params JSON;
  _param JSON;
  _param_idx INT;
  _param_list hafbe_backend.endpoint_parameter[];
  _param_obj hafbe_backend.endpoint_parameter;
  _responses JSON;
  _return_type TEXT;
  _content JSON;
  _tags TEXT[];
  _tag_idx INT;
  _rpc_function TEXT;
  _installed BOOLEAN;
  _mismatch_reason TEXT;
  _func_schema TEXT;
  _func_name TEXT;
  _func_found BOOLEAN;
  _db_argnames TEXT[];
  _db_argtypes TEXT[];
  _db_rettype TEXT;
  _openapi_argnames TEXT[];
  _openapi_argcount INT;
  _i INT;
  _db_argname TEXT;
  _openapi_argname TEXT;
  _reasons TEXT[];
BEGIN
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=3600"}]', true);

  _openapi_spec := hafbe_endpoints.root();
  _version := (_openapi_spec->'info'->>'version')::TEXT;
  _paths := _openapi_spec->'paths';

  FOR _path_key, _methods IN SELECT * FROM json_each(_paths) LOOP
    FOR _method_key, _method_data IN SELECT * FROM json_each(_methods) LOOP
      _tags := ARRAY[]::TEXT[];
      IF json_typeof(_method_data->'tags') = 'array' THEN
        FOR _tag_idx IN 0..json_array_length(_method_data->'tags') - 1 LOOP
          _tags := array_append(_tags, json_extract_path_text(_method_data, 'tags', _tag_idx::TEXT));
        END LOOP;
      END IF;

      _param_list := ARRAY[]::hafbe_backend.endpoint_parameter[];
      _openapi_argnames := ARRAY[]::TEXT[];
      _params := _method_data->'parameters';
      IF json_typeof(_params) = 'array' THEN
        FOR _param_idx IN 0..json_array_length(_params) - 1 LOOP
          _param := json_extract_path(_method_data, 'parameters', _param_idx::TEXT);
          _param_obj := ROW(
            json_extract_path_text(_param, 'name'),
            json_extract_path_text(_param, 'in'),
            COALESCE((json_extract_path_text(_param, 'required'))::BOOLEAN, FALSE),
            CASE
              WHEN json_extract_path(_param, 'schema') ? 'type' THEN json_extract_path_text(_param, 'schema', 'type')
              WHEN json_extract_path(_param, 'schema') ? '$ref' THEN split_part(json_extract_path_text(_param, 'schema', '$ref'), '/', 4)
              ELSE 'string'
            END,
            json_extract_path(_param, 'schema', 'default'),
            json_extract_path_text(_param, 'description')
          )::hafbe_backend.endpoint_parameter;
          _param_list := array_append(_param_list, _param_obj);
          _openapi_argnames := array_append(_openapi_argnames, json_extract_path_text(_param, 'name'));
        END LOOP;
      END IF;

      _return_type := 'unknown';
      _responses := _method_data->'responses';
      IF json_extract_path(_responses, '200') IS NOT NULL THEN
        _content := json_extract_path(_responses, '200', 'content', 'application/json', 'schema');
        IF _content IS NOT NULL THEN
          IF json_extract_path_text(_content, 'type') IS NOT NULL THEN
            _return_type := json_extract_path_text(_content, 'type');
          ELSIF json_extract_path_text(_content, '$ref') IS NOT NULL THEN
            _return_type := split_part(json_extract_path_text(_content, '$ref'), '/', 4);
          ELSIF json_extract_path_text(_content, 'items', '$ref') IS NOT NULL THEN
            _return_type := split_part(json_extract_path_text(_content, 'items', '$ref'), '/', 4) || '[]';
          END IF;
        END IF;
      END IF;

      _rpc_function := json_extract_path_text(_method_data, 'operationId');
      _installed := FALSE;
      _mismatch_reason := NULL;
      _reasons := ARRAY[]::TEXT[];

      IF _rpc_function IS NOT NULL AND _rpc_function LIKE '%.%' THEN
        _func_schema := split_part(_rpc_function, '.', 1);
        _func_name   := split_part(_rpc_function, '.', 2);

        SELECT
          p.pronargs,
          p.proargnames,
          ARRAY(
            SELECT format_type(pt.oid, NULL)
            FROM unnest(p.proargtypes) WITH ORDINALITY AS pt(oid, ord)
          ),
          format_type(p.prorettype, NULL)
        INTO
          _openapi_argcount,
          _db_argnames,
          _db_argtypes,
          _db_rettype
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = _func_schema
          AND p.proname = _func_name;

        _func_found := (_openapi_argcount IS NOT NULL);

        IF NOT _func_found THEN
          _reasons := array_append(_reasons, 'function_not_found');
        ELSE
          IF array_length(_openapi_argnames, 1) IS DISTINCT FROM _openapi_argcount THEN
            _reasons := array_append(_reasons, 'parameter_count_mismatch:openapi=' || COALESCE(array_length(_openapi_argnames, 1)::TEXT, '0') || ',db=' || _openapi_argcount::TEXT);
          ELSE
            FOR _i IN 1..COALESCE(array_length(_openapi_argnames, 1), 0) LOOP
              _openapi_argname := _openapi_argnames[_i];
              _db_argname := _db_argnames[_i];
              IF _db_argname IS DISTINCT FROM _openapi_argname THEN
                _reasons := array_append(_reasons, 'parameter_name_mismatch:openapi=' || COALESCE(_openapi_argname, '<null>') || ',db=' || COALESCE(_db_argname, '<null>'));
              END IF;
            END LOOP;
          END IF;

          IF _return_type != 'unknown' AND _db_rettype IS NOT NULL THEN
            IF _db_rettype != _return_type
               AND _db_rettype != replace(_return_type, '.', '_')
               AND _func_schema || '.' || _db_rettype != _return_type THEN
              _reasons := array_append(_reasons, 'return_type_mismatch:openapi=' || _return_type || ',db=' || _db_rettype);
            END IF;
          END IF;
        END IF;

        IF array_length(_reasons, 1) IS NULL THEN
          _installed := TRUE;
          _mismatch_reason := NULL;
        ELSE
          _installed := FALSE;
          _mismatch_reason := array_to_string(_reasons, '; ');
        END IF;
      ELSE
        _reasons := array_append(_reasons, 'invalid_operation_id');
        _mismatch_reason := array_to_string(_reasons, '; ');
      END IF;

      _endpoint := ROW(
        _path_key,
        _method_key,
        _tags,
        json_extract_path_text(_method_data, 'summary'),
        json_extract_path_text(_method_data, 'description'),
        _rpc_function,
        _installed,
        _mismatch_reason,
        _param_list,
        _return_type,
        _version
      )::hafbe_backend.endpoint_metadata;
      _endpoints := array_append(_endpoints, _endpoint);
    END LOOP;
  END LOOP;

  RETURN ROW(_version, _endpoints)::hafbe_backend.endpoints_response;
END
$$;

RESET ROLE;

SET ROLE hafbe_owner;

-- Table to store rewrite rules for self-check validation
DROP TABLE IF EXISTS hafbe_backend.rewrite_rules CASCADE;
CREATE TABLE hafbe_backend.rewrite_rules (
    path TEXT PRIMARY KEY,
    target_rpc TEXT NOT NULL,
    method TEXT DEFAULT 'get'
);

-- Function to load rewrite rules from the config file content
-- Called by install_app.sh after installation
DROP FUNCTION IF EXISTS hafbe_backend.load_rewrite_rules(TEXT);
CREATE OR REPLACE FUNCTION hafbe_backend.load_rewrite_rules(_config_content TEXT)
RETURNS INTEGER
LANGUAGE 'plpgsql' VOLATILE
AS
$$
DECLARE
  _line TEXT;
  _lines TEXT[];
  _i INTEGER;
  _pattern TEXT;
  _target_full TEXT;
  _target_path TEXT;
  _query_string TEXT;
  _target TEXT;
  _count INTEGER := 0;
  _path TEXT;
  _j INTEGER;
  _capture_idx INTEGER;
  _param_name TEXT;
  _param_parts TEXT[];
  _param_kv TEXT;
BEGIN
  TRUNCATE TABLE hafbe_backend.rewrite_rules;

  _lines := string_to_array(_config_content, E'\n');

  FOR _i IN 1..array_length(_lines, 1) LOOP
    _line := _lines[_i];
    IF _line LIKE 'rewrite ^/% /rpc/%' THEN
      _pattern := substring(_line, 'rewrite (\^/[^ ]+) /rpc/');
      _target_full := substring(_line, '/rpc/([^ ]+)');

      IF _pattern IS NOT NULL AND _target_full IS NOT NULL THEN
        IF position('?' IN _target_full) > 0 THEN
          _target := split_part(_target_full, '?', 1);
          _query_string := split_part(_target_full, '?', 2);
        ELSE
          _target := _target_full;
          _query_string := NULL;
        END IF;

        _pattern := substring(_pattern, 2); -- strip leading ^

        IF _query_string IS NOT NULL THEN
          _param_parts := string_to_array(_query_string, '&');
          FOR _j IN 1..array_length(_param_parts, 1) LOOP
            _param_kv := _param_parts[_j];
            _param_name := split_part(_param_kv, '=', 1);
            _capture_idx := split_part(_param_kv, '=', 2);
            IF _capture_idx LIKE '$%' THEN
              _capture_idx := substring(_capture_idx, 2)::INTEGER;
              _pattern := regexp_replace(_pattern, '\(\[\^/\]\+\)', '{' || _param_name || '}', 'i');
            END IF;
          END LOOP;
        END IF;

        _pattern := regexp_replace(_pattern, '\(\[\^/\]\+\)', '{unknown_' || _count || '}', 'g');
        _pattern := replace(_pattern, '+', '');

        INSERT INTO hafbe_backend.rewrite_rules (path, target_rpc)
        VALUES (_pattern, _target)
        ON CONFLICT (path) DO UPDATE SET target_rpc = EXCLUDED.target_rpc;
        _count := _count + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN _count;
END
$$;

RESET ROLE;

SET ROLE hafbe_owner;
GRANT SELECT ON hafbe_backend.rewrite_rules TO hafbe_user;
GRANT EXECUTE ON FUNCTION hafbe_backend.load_rewrite_rules(TEXT) TO hafbe_owner;
RESET ROLE;

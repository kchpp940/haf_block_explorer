-- =============================================================================
-- HAFBE Test Bootstrap Diagnostics
-- =============================================================================
--
-- Structured diagnostic functions used by scripts/test_bootstrap.py to report:
--   1. Missing tables / schemas
--   2. Missing block ranges (gaps in the mock block window)
--   3. Endpoint / assertion mismatches with expected vs actual
--
-- All functions return SETOF rows that the Python caller renders as
-- human-readable tables with clear FAIL / PASS indicators.
-- =============================================================================

SET ROLE hafbe_owner;

-- -----------------------------------------------------------------------------
-- 1. Schema / table completeness
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION hafbe_backend.diagnose_missing_tables()
RETURNS TABLE(
    schema_name  TEXT,
    object_type  TEXT,
    object_name  TEXT,
    status       TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _expected RECORD;
    _exists   BOOLEAN;
BEGIN
    -- (schema, type, name) tuples we require after a successful HAFBE install.
    -- Keep this list in sync with db/hafbe_app.sql and endpoints/endpoint_schema.sql.
    FOR _expected IN VALUES
        ('hafbe_app',       'schema', NULL),
        ('hafbe_backend',   'schema', NULL),
        ('hafbe_endpoints', 'schema', NULL),
        ('hafbe_app',       'table',  'current_proposals'),
        ('hafbe_app',       'table',  'current_proposal_votes'),
        ('hafbe_app',       'table',  'proposal_payments'),
        ('hafbe_app',       'table',  'proposal_votes_history'),
        ('hafbe_app',       'table',  'proposal_vote_stats_cache'),
        ('hafbe_app',       'table',  'current_witnesses'),
        ('hafbe_app',       'table',  'current_witness_votes'),
        ('hafbe_app',       'table',  'witness_votes_cache'),
        ('hafbe_app',       'table',  'account_parameters'),
        ('hafbe_app',       'table',  'current_account_proxies'),
        ('hafbe_app',       'table',  'app_status'),
        ('hafbe_backend',   'function', 'insert_mock_blocks'),
        ('hafbe_backend',   'function', 'insert_mock_operations'),
        ('hafbe_backend',   'function', 'update_irreversible_block'),
        ('hafbe_endpoints', 'function', 'get_proposals'),
        ('hafbe_endpoints', 'function', 'get_proposal_votes'),
        ('hafbe_endpoints', 'function', 'get_witness'),
        ('hafbe_endpoints', 'function', 'get_witnesses')
    AS t(schema_name, object_type, object_name)
    LOOP
        IF _expected.object_type = 'schema' THEN
            SELECT EXISTS (
                SELECT 1 FROM information_schema.schemata s
                WHERE s.schema_name = _expected.schema_name
            ) INTO _exists;
        ELSIF _expected.object_type = 'table' THEN
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables t
                WHERE t.table_schema = _expected.schema_name
                  AND t.table_name   = _expected.object_name
            ) INTO _exists;
        ELSIF _expected.object_type = 'function' THEN
            SELECT EXISTS (
                SELECT 1 FROM information_schema.routines r
                WHERE r.routine_schema = _expected.schema_name
                  AND r.routine_name   = _expected.object_name
                  AND r.routine_type   = 'FUNCTION'
            ) INTO _exists;
        END IF;

        RETURN QUERY SELECT
            _expected.schema_name,
            _expected.object_type,
            COALESCE(_expected.object_name, '(schema itself)'),
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END;
    END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- 2. Mock block range completeness
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION hafbe_backend.diagnose_mock_block_range(
    _window_start INT DEFAULT 91000000,
    _window_end   INT DEFAULT 91000099
)
RETURNS TABLE(
    check_name    TEXT,
    expected      TEXT,
    actual        TEXT,
    status        TEXT,
    detail        TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _min_block       INT;
    _max_block       INT;
    _block_count     INT;
    _expected_count  INT;
    _missing_blocks  INT[];
    _missing_text    TEXT;
    _op_count        INT;
BEGIN
    SELECT MIN(b.num), MAX(b.num), COUNT(*)
      INTO _min_block, _max_block, _block_count
      FROM hafd.blocks b
     WHERE b.num BETWEEN _window_start AND _window_end;

    check_name := 'mock block range present';
    expected   := format('blocks %s..%s', _window_start, _window_end);

    IF _min_block IS NULL THEN
        actual := 'no blocks in window';
        status := 'FAIL';
        detail := format(
            'hafd.blocks has NO rows between %s and %s',
            _window_start, _window_end
        );
        RETURN NEXT;
    ELSE
        actual := format('blocks %s..%s (%s total)', _min_block, _max_block, _block_count);

        _expected_count := _max_block - _min_block + 1;
        IF _block_count = _expected_count THEN
            status := 'PASS';
            detail := 'no gaps';
        ELSE
            status := 'FAIL';
            SELECT ARRAY(
                SELECT gs::INT
                FROM generate_series(_min_block, _max_block) gs
                WHERE NOT EXISTS (
                    SELECT 1 FROM hafd.blocks b WHERE b.num = gs
                )
                ORDER BY gs
            ) INTO _missing_blocks;
            detail := format(
                'missing %s block(s): %s',
                array_length(_missing_blocks, 1),
                array_to_string(_missing_blocks, ', ')
            );
        END IF;
        RETURN NEXT;
    END IF;

    SELECT COUNT(*) INTO _op_count
      FROM hafd.operations o
     WHERE hafd.operation_id_block_num(o.id) BETWEEN _min_block AND _max_block;

    check_name := 'mock operations present';
    expected   := '> 0 operations in mock range';
    actual     := _op_count::TEXT || ' operations';
    IF _op_count > 0 THEN
        status := 'PASS';
        detail := 'operations loaded';
    ELSE
        status := 'FAIL';
        detail := 'no operations found in mock block range — insert_mock_operations() may not have run';
    END IF;
    RETURN NEXT;
END
$$;

-- -----------------------------------------------------------------------------
-- 3. HAF context state
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION hafbe_backend.diagnose_context_state(
    _window_start INT DEFAULT 91000000,
    _window_end   INT DEFAULT 91000099
)
RETURNS TABLE(
    context_name     TEXT,
    current_block    INT,
    irreversible_block INT,
    consistent_block INT,
    status           TEXT,
    detail           TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _consistent INT;
    _rec        RECORD;
BEGIN
    SELECT hs.consistent_block INTO _consistent FROM hafd.hive_state hs;

    FOR _rec IN
        SELECT c.name, c.current_block_num, c.irreversible_block
          FROM hafd.contexts c
         WHERE c.name IN ('hafbe_app', 'hafbe_bal')
         ORDER BY c.name
    LOOP
        context_name     := _rec.name;
        current_block    := _rec.current_block_num;
        irreversible_block := _rec.irreversible_block;
        consistent_block := _consistent;

        IF _consistent < _window_start THEN
            status := 'FAIL';
            detail := format(
                'consistent_block %s < mock window start %s — update_irreversible_block() not called?',
                _consistent, _window_start
            );
        ELSIF _rec.current_block_num < _window_start - 1 THEN
            status := 'FAIL';
            detail := format(
                'current_block_num %s too low — context has not reached mock window',
                _rec.current_block_num
            );
        ELSIF _rec.current_block_num >= _window_start AND _rec.current_block_num < _consistent THEN
            status := 'IN_PROGRESS';
            detail := format(
                'context at %s, consistent at %s — processing not yet complete',
                _rec.current_block_num, _consistent
            );
        ELSIF _rec.current_block_num >= _consistent THEN
            status := 'PASS';
            detail := 'context synced to consistent_block';
        ELSE
            status := 'PASS';
            detail := format('context positioned at %s', _rec.current_block_num);
        END IF;
        RETURN NEXT;
    END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- 4. Regression test schema completeness
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION hafbe_backend.diagnose_regression_schema()
RETURNS TABLE(
    schema_name TEXT,
    object_type TEXT,
    object_name TEXT,
    status      TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _expected RECORD;
    _exists   BOOLEAN;
BEGIN
    FOR _expected IN VALUES
        ('hafbe_test', 'schema', NULL),
        ('hafbe_test', 'table',  'expected_account_stats'),
        ('hafbe_test', 'table',  'expected_witness_props'),
        ('hafbe_test', 'table',  'differing_accounts'),
        ('hafbe_test', 'table',  'differing_witnesses'),
        ('hafbe_test', 'function', 'compare_accounts'),
        ('hafbe_test', 'function', 'compare_witnesses'),
        ('hafbe_test', 'function', 'load_expected_account_stats'),
        ('hafbe_test', 'function', 'load_expected_witness_props')
    AS t(schema_name, object_type, object_name)
    LOOP
        IF _expected.object_type = 'schema' THEN
            SELECT EXISTS (
                SELECT 1 FROM information_schema.schemata s
                WHERE s.schema_name = _expected.schema_name
            ) INTO _exists;
        ELSIF _expected.object_type = 'table' THEN
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables t
                WHERE t.table_schema = _expected.schema_name
                  AND t.table_name   = _expected.object_name
            ) INTO _exists;
        ELSIF _expected.object_type = 'function' THEN
            SELECT EXISTS (
                SELECT 1 FROM information_schema.routines r
                WHERE r.routine_schema = _expected.schema_name
                  AND r.routine_name   = _expected.object_name
                  AND r.routine_type   = 'FUNCTION'
            ) INTO _exists;
        END IF;

        RETURN QUERY SELECT
            _expected.schema_name,
            _expected.object_type,
            COALESCE(_expected.object_name, '(schema itself)'),
            CASE WHEN _exists THEN 'PASS' ELSE 'FAIL' END;
    END LOOP;
END
$$;

-- -----------------------------------------------------------------------------
-- 5. Expected data freshness (how many rows in hafbe_test.expected_* tables)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION hafbe_backend.diagnose_expected_data_load()
RETURNS TABLE(
    table_name TEXT,
    row_count  BIGINT,
    status     TEXT,
    detail     TEXT
)
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    _cnt BIGINT;
BEGIN
    SELECT COUNT(*) INTO _cnt FROM hafbe_test.expected_account_stats;
    RETURN QUERY SELECT
        'hafbe_test.expected_account_stats',
        _cnt,
        CASE WHEN _cnt > 0 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _cnt > 0 THEN 'expected account data loaded'
             ELSE 'no rows — run regression-install or load_expected_data.py' END;

    SELECT COUNT(*) INTO _cnt FROM hafbe_test.expected_witness_props;
    RETURN QUERY SELECT
        'hafbe_test.expected_witness_props',
        _cnt,
        CASE WHEN _cnt > 0 THEN 'PASS' ELSE 'FAIL' END,
        CASE WHEN _cnt > 0 THEN 'expected witness data loaded'
             ELSE 'no rows — run regression-install or load_expected_data.py' END;
END
$$;

RESET ROLE;

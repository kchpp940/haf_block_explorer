SET ROLE hafbe_owner;

/*
 * processing_pipeline: Unified definition of HAFBE's block processing pipeline.
 *
 * PROBLEM THIS SOLVES:
 *   Previously, cache refresh and incremental processing were scattered across
 *   process_witness_votes.sql, process_proposals.sql, process_transaction_stats.sql,
 *   hafbe_app.sql, and install_app.sh. Dependencies were documented only in
 *   isolated comments, and adding a new processor required auditing 5+ files.
 *
 * THIS FILE IS THE SINGLE SOURCE OF TRUTH for:
 *   - Which processors exist
 *   - What order they run in
 *   - Which mode(s) each runs in (MASSIVE / LIVE / BOTH)
 *   - What each processor depends on (prerequisites)
 *   - What tables each refreshes (targets)
 *   - Idempotency guarantees (safe to re-run?)
 *
 * ADDING A NEW PROCESSOR?
 *   1. Insert a row into hafbe_app.processing_pipeline (see template at bottom)
 *   2. Create db/process_<name>.sql with the processor function
 *   3. Add the file to scripts/install_app.sh (after process_block_operations.sql
 *      if it's a state processor, after process_proposal_vote_stats_cache.sql
 *      if it's a cache processor)
 *   4. Update scripts/claude/processing.md with a one-liner
 *
 * That's it. No need to edit massive_processing(), single_processing(), or
 * process_blocks() — the dispatch functions read from this table.
 */

-- ============================================================================
-- PIPELINE DEFINITION TABLE
-- ============================================================================
--
-- This table is the authoritative list of all processors.  The dispatch
-- functions (run_pipeline_massive / run_pipeline_live) iterate over it in
-- execution_order.
--
-- Columns:
--   processor_id        : Stable unique key (never change after merge)
--   execution_order     : Run order within each stage (ascending)
--   processor_name      : Human-readable name (matches function name without schema)
--   function_schema     : Schema where the function lives
--   function_name       : SQL function/procedure name
--   function_signature  : '(_from INT, _to INT)' for state processors, '()' for cache
--   run_in_massive      : TRUE to run during MASSIVE_PROCESSING stage
--   run_in_live         : TRUE to run during LIVE stage (per block)
--   prerequisites       : Array of processor_id that MUST complete before this one
--   target_tables       : Array of table names (without schema) this processor writes to
--                         (all tables are in hafbe_app schema; used for vacuum requests)
--   idempotency         : 'FULLY' = safe to re-run any range
--                         'RANGE' = safe to re-run same [_from,_to] range
--                         'NONE' = re-running causes duplicates / corruption
--   description         : One-line purpose (shows up in \d+ and docs)

CREATE TABLE IF NOT EXISTS hafbe_app.processing_pipeline (
    processor_id        TEXT        NOT NULL  PRIMARY KEY,
    execution_order     INT         NOT NULL  UNIQUE,
    processor_name      TEXT        NOT NULL  UNIQUE,
    function_schema     TEXT        NOT NULL,
    function_name       TEXT        NOT NULL,
    function_signature  TEXT        NOT NULL,
    run_in_massive      BOOLEAN     NOT NULL  DEFAULT TRUE,
    run_in_live         BOOLEAN     NOT NULL  DEFAULT TRUE,
    prerequisites       TEXT[]      NOT NULL  DEFAULT '{}',
    target_tables       TEXT[]      NOT NULL  DEFAULT '{}',
    idempotency         TEXT        NOT NULL  CHECK (idempotency IN ('FULLY', 'RANGE', 'NONE')),
    description         TEXT        NOT NULL
);

-- ============================================================================
-- VALIDATION STATE TABLE
-- ============================================================================
-- Tracks the last successful pipeline validation to avoid re-validating on every block.
--
-- pipeline_version is auto-incremented by trigger on ANY change to processing_pipeline.
-- Runtime check compares this single value — no table scans, no hash computations.
--
-- Full validation (expensive, scans pg_proc/pg_class + recursive dependency checks)
-- runs:
--   - At install time (install_app.sh)
--   - When manually called (SELECT hafbe_app.validate_processing_pipeline())
--
-- Runtime check (ZERO extra table scans):
--   - Runs before every run_pipeline_*() call
--   - Single-row comparison: last_validated_version == current_pipeline_version

CREATE TABLE IF NOT EXISTS hafbe_app.pipeline_validation_state (
    state_id                TEXT        NOT NULL  PRIMARY KEY DEFAULT 'current',
    current_pipeline_version INT        NOT NULL  DEFAULT 1,
    last_validated_version   INT        NOT NULL  DEFAULT 0,
    validated_modes         TEXT[]      NOT NULL  DEFAULT '{}',
    validated_at            TIMESTAMPTZ NOT NULL  DEFAULT NOW(),
    CONSTRAINT state_id_check CHECK (state_id = 'current')
);

-- Initialize the single row if it doesn't exist yet
INSERT INTO hafbe_app.pipeline_validation_state (state_id)
VALUES ('current')
ON CONFLICT DO NOTHING;

-- Trigger to bump current_pipeline_version on ANY change to processing_pipeline.
-- This ensures we never miss a configuration change — runtime checks will see
-- the version mismatch and prompt for re-validation.
CREATE OR REPLACE FUNCTION hafbe_app._pipeline_config_changed()
RETURNS TRIGGER
LANGUAGE 'plpgsql'
AS $$
BEGIN
    UPDATE hafbe_app.pipeline_validation_state
    SET current_pipeline_version = current_pipeline_version + 1
    WHERE state_id = 'current';
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS _trigger_pipeline_changed ON hafbe_app.processing_pipeline;
CREATE TRIGGER _trigger_pipeline_changed
    AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE
    ON hafbe_app.processing_pipeline
    FOR EACH STATEMENT
    EXECUTE FUNCTION hafbe_app._pipeline_config_changed();

-- ============================================================================
-- STAGE 1: STATE PROCESSORS
-- ============================================================================
-- These process raw blockchain operations into materialized state tables.
-- They run in BOTH MASSIVE and LIVE modes.
-- Ordering matters: later processors may read tables written by earlier ones.

-- 1. account_stats: account creation, recovery, voting rights, claimed accounts
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'account_stats', 10, 'process_account_stats',
    'hafbe_app', 'process_account_stats', '(_from INT, _to INT)',
    TRUE, TRUE, '{}',
    ARRAY['account_parameters'],
    'RANGE',
    'Account creation metadata, recovery tracking, voting rights, claimed account tokens'
) ON CONFLICT DO NOTHING;

-- 2. block_operations: per-block op counts + per-day/month per-op-type rollups
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'block_operations', 20, 'process_block_operations',
    'hafbe_app', 'process_block_operations', '(_from INT, _to INT)',
    TRUE, TRUE, '{}',
    ARRAY['block_operations',
          'operation_type_stats_by_day',
          'operation_type_stats_by_month'],
    'RANGE',
    'Operation counts per block and per-operation-type daily/monthly rollups'
) ON CONFLICT DO NOTHING;

-- 3. transaction_stats: daily/monthly transaction count aggregations
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'transaction_stats', 30, 'process_transaction_stats',
    'hafbe_app', 'process_transaction_stats', '(_from INT, _to INT)',
    TRUE, TRUE, '{}',
    ARRAY['transaction_stats_by_day',
          'transaction_stats_by_month'],
    'RANGE',
    'Daily and monthly transaction count aggregations (sum/min/max per period)'
) ON CONFLICT DO NOTHING;

-- 4. witness_stats: witness metadata (url, signing key, price feed, version, etc.)
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'witness_stats', 40, 'process_witness_stats',
    'hafbe_app', 'process_witness_stats', '(_from INT, _to INT)',
    TRUE, TRUE, '{}',
    ARRAY['current_witnesses'],
    'RANGE',
    'Witness configuration, price feeds, missed blocks, version tracking'
) ON CONFLICT DO NOTHING;

-- 5. witness_votes: witness vote and proxy state (row-by-row for cascade correctness)
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'witness_votes', 50, 'process_witness_votes',
    'hafbe_app', 'process_witness_votes', '(_from INT, _to INT)',
    TRUE, TRUE, '{}',
    ARRAY['witness_votes_history',
          'current_witness_votes',
          'account_proxies_history',
          'current_account_proxies'],
    'RANGE',
    'Witness vote and proxy state with sequential processing for cascade correctness'
) ON CONFLICT DO NOTHING;

-- 6. proposals: ALL proposal ops in one unified row-by-row processor
--    (create/update/remove/pay/vote + decline/expired cleanup)
--    Reads account_parameters (can_vote flag) and current_witness_votes (for
--    expired_account cascades), so depends on account_stats and witness_votes.
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'proposals', 60, 'process_proposals',
    'hafbe_app', 'process_proposals', '(_from INT, _to INT)',
    TRUE, TRUE, ARRAY['account_stats', 'witness_votes'],
    ARRAY['proposal_votes_history',
          'current_proposal_votes',
          'current_proposals',
          'proposal_payments'],
    'RANGE',
    'Unified processor for all proposal ops: create (paired with fee) / update / remove / pay / votes / decline / expired'
) ON CONFLICT DO NOTHING;

-- ============================================================================
-- STAGE 2: CACHE REFRESH (LIVE MODE ONLY)
-- ============================================================================
-- These rebuild cache tables after each LIVE block.
-- They are NOT called during MASSIVE sync (caches are seeded once at the
-- MASSIVE → LIVE transition, then refreshed per-block thereafter).

-- 7. witness_votes_cache: rebuilds witness vote caches (LIVE only)
--    Must run before proposal_vote_stats_cache (depends on account_vest_stats_cache)
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'witness_votes_cache', 100, 'process_witness_votes_cache',
    'hafbe_app', 'process_witness_votes_cache', '()',
    FALSE, TRUE, ARRAY['witness_votes'],
    ARRAY['account_vest_stats_cache',
          'witness_votes_cache',
          'witness_rank_cache',
          'witness_votes_change_cache'],
    'FULLY',
    'Full refresh of witness vote caches: account vest stats, vote totals, rankings, daily change'
) ON CONFLICT DO NOTHING;

-- 8. proposal_vote_stats_cache: stake-weighted proposal vote totals (LIVE only)
--    Depends on witness_votes_cache for fresh account_vest_stats_cache
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'proposal_vote_stats_cache', 110, 'process_proposal_vote_stats_cache',
    'hafbe_app', 'process_proposal_vote_stats_cache', '()',
    FALSE, TRUE, ARRAY['proposals', 'witness_votes_cache'],
    ARRAY['proposal_vote_stats_cache'],
    'FULLY',
    'Stake-weighted proposal vote totals, excluding voters with governance proxies'
) ON CONFLICT DO NOTHING;

-- ============================================================================
-- DISPATCH FUNCTIONS
-- ============================================================================
-- These read the pipeline table and execute processors in order.
-- No need to edit these when adding a new processor — just insert a row above.

/*
 * run_pipeline_massive: Execute all state processors for a block range.
 *
 * Iterates the pipeline table in execution_order, calling each processor
 * marked run_in_massive=TRUE.  Cache processors are skipped during MASSIVE.
 */
CREATE OR REPLACE PROCEDURE hafbe_app.run_pipeline_massive(
    IN _from INT,
    IN _to INT
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
    _proc RECORD;
BEGIN
    PERFORM hafbe_app.is_pipeline_valid('MASSIVE');
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE run_in_massive = TRUE
        ORDER BY execution_order
    LOOP
        EXECUTE format(
            'SELECT %I.%I(%s, %s)',
            _proc.function_schema, _proc.function_name,
            _from, _to
        );
    END LOOP;
END
$$;

/*
 * run_pipeline_live: Execute ALL processors (state + cache) for a single block.
 *
 * Iterates the pipeline table in execution_order, calling each processor
 * marked run_in_live=TRUE.  State processors get (_block, _block) as range;
 * cache processors take no arguments.
 */
CREATE OR REPLACE PROCEDURE hafbe_app.run_pipeline_live(
    IN _block INT
)
LANGUAGE 'plpgsql'
AS
$$
DECLARE
    _proc RECORD;
BEGIN
    PERFORM hafbe_app.is_pipeline_valid('LIVE');
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE run_in_live = TRUE
        ORDER BY execution_order
    LOOP
        IF _proc.function_signature = '()' THEN
            EXECUTE format(
                'SELECT %I.%I()',
                _proc.function_schema, _proc.function_name
            );
        ELSE
            EXECUTE format(
                'SELECT %I.%I(%s, %s)',
                _proc.function_schema, _proc.function_name,
                _block, _block
            );
        END IF;
    END LOOP;
END
$$;

/*
 * run_pipeline_cache_seed: Seed all cache tables at MASSIVE → LIVE transition.
 *
 * Called once when first entering LIVE mode, before processing any LIVE blocks.
 * Runs all cache processors (execution_order >= 100) to ensure API endpoints
 * that depend on caches return correct data immediately.
 */
CREATE OR REPLACE FUNCTION hafbe_app.run_pipeline_cache_seed()
RETURNS VOID
LANGUAGE 'plpgsql'
AS
$$
DECLARE
    _proc RECORD;
BEGIN
    PERFORM hafbe_app.is_pipeline_valid('LIVE');
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE run_in_live = TRUE
          AND execution_order >= 100
        ORDER BY execution_order
    LOOP
        EXECUTE format(
            'SELECT %I.%I()',
            _proc.function_schema, _proc.function_name
        );
    END LOOP;
END
$$;

/*
 * get_pipeline_vacuum_tables: Get list of tables that need vacuuming.
 *
 * Returns target_tables from all processors that run in the current stage.
 * Used by process_blocks() to request periodic vacuum.
 */
CREATE OR REPLACE FUNCTION hafbe_app.get_pipeline_vacuum_tables(
    _stage TEXT
)
RETURNS SETOF TEXT
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
    _proc RECORD;
    _tbl  TEXT;
BEGIN
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE CASE _stage
            WHEN 'MASSIVE' THEN run_in_massive
            WHEN 'LIVE'    THEN run_in_live
            ELSE TRUE
        END
        ORDER BY execution_order
    LOOP
        FOREACH _tbl IN ARRAY _proc.target_tables LOOP
            RETURN NEXT _tbl;
        END LOOP;
    END LOOP;
    RETURN;
END
$$;

-- ============================================================================
-- VALIDATION FUNCTIONS
-- ============================================================================
-- Full validation (expensive, scans pg_proc/pg_class + recursive checks) runs:
--   - At install time (install_app.sh)
--   - When manually called: SELECT hafbe_app.validate_processing_pipeline()
--
-- Runtime check (cheap, single-row lookup) runs before every run_pipeline_*() call.

/*
 * is_pipeline_valid: Lightweight runtime check - is pipeline validated for this mode?
 *
 * Does NOT do full validation. Just checks:
 *   1. last_validated_version == current_pipeline_version (single integer comparison)
 *   2. The requested mode was validated in that last run
 *
 * ZERO table scans of processing_pipeline — version bumps via trigger.
 *
 * Raises an EXCEPTION with user guidance if validation is needed.
 * Called before every run_pipeline_*() dispatch.
 */
CREATE OR REPLACE FUNCTION hafbe_app.is_pipeline_valid(
    _mode TEXT
)
RETURNS BOOLEAN
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
    _state RECORD;
BEGIN
    SELECT * INTO _state
    FROM hafbe_app.pipeline_validation_state
    WHERE state_id = 'current';

    IF _state.last_validated_version = 0 THEN
        RAISE EXCEPTION
            'Processing pipeline has not been validated.%'
            'Run: SELECT hafbe_app.validate_processing_pipeline();',
            chr(10);
    END IF;

    IF _state.last_validated_version != _state.current_pipeline_version THEN
        RAISE EXCEPTION
            'Processing pipeline configuration has changed since last validation.%'
            'Run: SELECT hafbe_app.validate_processing_pipeline();',
            chr(10);
    END IF;

    IF NOT (_mode = ANY(_state.validated_modes)) THEN
        RAISE EXCEPTION
            'Processing pipeline not validated for % mode.%'
            'Run: SELECT hafbe_app.validate_processing_pipeline();',
            _mode, chr(10);
    END IF;

    RETURN TRUE;
END
$$;

/*
 * validate_processing_pipeline: Validate pipeline configuration for a mode.
 *
 * Checks:
 *   1. processor_id is unique
 *   2. execution_order is unique
 *   3. All prerequisites exist in the same mode and have earlier execution_order
 *   4. The processor function exists with matching signature
 *   5. target_tables entries are valid table names (no schema prefix, table exists)
 *   6. No circular dependencies
 *
 * Raises EXCEPTION with detailed message if any check fails.
 * Use _mode = 'MASSIVE', 'LIVE', or NULL (check all).
 */
CREATE OR REPLACE FUNCTION hafbe_app.validate_processing_pipeline(
    _mode TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE 'plpgsql'
VOLATILE
AS
$$
DECLARE
    _proc RECORD;
    _dep RECORD;
    _prereq_id TEXT;
    _schema_name TEXT;
    _func_name TEXT;
    _expected_args INT;
    _actual_args INT;
    _table_name TEXT;
    _has_schema_dot BOOLEAN;
    _table_exists BOOLEAN;
    _violations TEXT[] := '{}';
    _visited TEXT[] := '{}';
    _path TEXT[] := '{}';
    _current_version INT;
    _state RECORD;

    FUNCTION add_violation(_msg TEXT) RETURNS VOID AS $$
    BEGIN
        _violations := array_append(_violations, _msg);
    END $$;

    FUNCTION check_circular(_proc_id TEXT, _current_path TEXT[]) RETURNS BOOLEAN AS $$
    DECLARE
        _p RECORD;
        _dep_id TEXT;
    BEGIN
        IF _proc_id = ANY(_current_path) THEN
            add_violation(format(
                'Circular dependency detected: %s',
                array_to_string(array_append(_current_path, _proc_id), ' -> ')
            ));
            RETURN TRUE;
        END IF;
        IF _proc_id = ANY(_visited) THEN
            RETURN FALSE;
        END IF;

        _visited := array_append(_visited, _proc_id);
        _current_path := array_append(_current_path, _proc_id);

        SELECT prerequisites INTO _p
        FROM hafbe_app.processing_pipeline
        WHERE processor_id = _proc_id;

        IF FOUND THEN
            FOREACH _dep_id IN ARRAY _p.prerequisites LOOP
                IF check_circular(_dep_id, _current_path) THEN
                    RETURN TRUE;
                END IF;
            END LOOP;
        END IF;

        RETURN FALSE;
    END $$;
BEGIN
    IF _mode IS NULL THEN
        PERFORM hafbe_app.validate_processing_pipeline('MASSIVE');
        PERFORM hafbe_app.validate_processing_pipeline('LIVE');
        RETURN;
    END IF;

    IF _mode NOT IN ('MASSIVE', 'LIVE') THEN
        RAISE EXCEPTION 'Invalid mode: % (must be MASSIVE, LIVE, or NULL)', _mode;
    END IF;

    -- Check 1: duplicate processor_id
    FOR _proc IN
        SELECT processor_id, COUNT(*) AS cnt
        FROM hafbe_app.processing_pipeline
        GROUP BY processor_id
        HAVING COUNT(*) > 1
    LOOP
        add_violation(format(
            'Duplicate processor_id: %s (appears %s times)',
            _proc.processor_id, _proc.cnt
        ));
    END LOOP;

    -- Check 2: duplicate execution_order within active processors
    FOR _proc IN
        SELECT execution_order, COUNT(*) AS cnt, array_agg(processor_id) AS procs
        FROM hafbe_app.processing_pipeline
        WHERE CASE _mode
            WHEN 'MASSIVE' THEN run_in_massive
            WHEN 'LIVE' THEN run_in_live
            ELSE TRUE
        END
        GROUP BY execution_order
        HAVING COUNT(*) > 1
    LOOP
        add_violation(format(
            'Duplicate execution_order %s in %s mode: %s',
            _proc.execution_order, _mode, array_to_string(_proc.procs, ', ')
        ));
    END LOOP;

    -- Check 3 & 6: prerequisites exist, have earlier order, no circular deps
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE CASE _mode
            WHEN 'MASSIVE' THEN run_in_massive
            WHEN 'LIVE' THEN run_in_live
            ELSE TRUE
        END
        ORDER BY execution_order
    LOOP
        -- Check for circular dependencies starting from this processor
        _visited := array_remove(_visited, _proc.processor_id);
        PERFORM check_circular(_proc.processor_id, '{}');

        FOREACH _prereq_id IN ARRAY _proc.prerequisites LOOP
            -- Prerequisite must exist
            IF NOT EXISTS (
                SELECT 1 FROM hafbe_app.processing_pipeline
                WHERE processor_id = _prereq_id
            ) THEN
                add_violation(format(
                    'Processor %s depends on non-existent prerequisite: %s',
                    _proc.processor_id, _prereq_id
                ));
                CONTINUE;
            END IF;

            -- Prerequisite must run in the same mode
            SELECT * INTO _dep
            FROM hafbe_app.processing_pipeline
            WHERE processor_id = _prereq_id;

            IF (_mode = 'MASSIVE' AND NOT _dep.run_in_massive)
               OR (_mode = 'LIVE' AND NOT _dep.run_in_live) THEN
                add_violation(format(
                    'Processor %s depends on %s, but %s does not run in %s mode',
                    _proc.processor_id, _prereq_id, _prereq_id, _mode
                ));
                CONTINUE;
            END IF;

            -- Prerequisite must have earlier execution_order
            IF _dep.execution_order >= _proc.execution_order THEN
                add_violation(format(
                    'Processor %s (order %s) depends on %s (order %s) which runs later',
                    _proc.processor_id, _proc.execution_order,
                    _prereq_id, _dep.execution_order
                ));
            END IF;
        END LOOP;
    END LOOP;

    -- Check 4: processor function exists with matching signature
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE CASE _mode
            WHEN 'MASSIVE' THEN run_in_massive
            WHEN 'LIVE' THEN run_in_live
            ELSE TRUE
        END
    LOOP
        _schema_name := _proc.function_schema;
        _func_name := _proc.function_name;

        -- Count expected arguments from signature
        IF _proc.function_signature = '()' THEN
            _expected_args := 0;
        ELSE
            _expected_args := array_length(
                string_to_array(
                    trim(both '()' FROM _proc.function_signature),
                    ','
                ),
                1
            );
        END IF;

        -- Check function exists in pg_proc
        SELECT pronargs INTO _actual_args
        FROM pg_proc
        JOIN pg_namespace n ON pronamespace = n.oid
        WHERE n.nspname = _schema_name
          AND proname = _func_name;

        IF NOT FOUND THEN
            add_violation(format(
                'Processor function not found: %I.%I (referenced by %s)',
                _schema_name, _func_name, _proc.processor_id
            ));
            CONTINUE;
        END IF;

        IF _actual_args != _expected_args THEN
            add_violation(format(
                'Processor %I.%I signature mismatch: declared %s but function takes %s args',
                _schema_name, _func_name, _proc.function_signature, _actual_args
            ));
        END IF;
    END LOOP;

    -- Check 5: target_tables are valid (no schema prefix, table exists)
    FOR _proc IN
        SELECT *
        FROM hafbe_app.processing_pipeline
        WHERE CASE _mode
            WHEN 'MASSIVE' THEN run_in_massive
            WHEN 'LIVE' THEN run_in_live
            ELSE TRUE
        END
    LOOP
        FOREACH _table_name IN ARRAY _proc.target_tables LOOP
            -- Should not contain schema prefix (dot)
            _has_schema_dot := position('.' IN _table_name) > 0;
            IF _has_schema_dot THEN
                add_violation(format(
                    'Processor %s target_table contains schema prefix: %s (use table name only)',
                    _proc.processor_id, _table_name
                ));
                CONTINUE;
            END IF;

            -- Table should exist in hafbe_app schema
            SELECT EXISTS (
                SELECT 1 FROM pg_tables
                WHERE schemaname = 'hafbe_app'
                  AND tablename = _table_name
            ) INTO _table_exists;

            IF NOT _table_exists THEN
                add_violation(format(
                    'Processor %s target_table does not exist: hafbe_app.%s',
                    _proc.processor_id, _table_name
                ));
            END IF;
        END LOOP;
    END LOOP;

    -- Report all violations
    IF array_length(_violations, 1) > 0 THEN
        RAISE EXCEPTION 'Processing pipeline validation failed for % mode:%',
            _mode, chr(10) || array_to_string(_violations, chr(10));
    END IF;

    -- Validation passed. Update the state table so runtime checks know it's safe.
    -- If _mode is NULL, we validated both MASSIVE and LIVE (via recursive calls).
    IF _mode IS NOT NULL THEN
        SELECT * INTO _state
        FROM hafbe_app.pipeline_validation_state
        WHERE state_id = 'current';

        _current_version := _state.current_pipeline_version;

        -- If this is the first mode we're validating for this version,
        -- reset validated_modes. Otherwise, just add to it.
        IF _state.last_validated_version != _current_version THEN
            -- New or changed configuration - fresh validation
            UPDATE hafbe_app.pipeline_validation_state
            SET last_validated_version = _current_version,
                validated_modes = ARRAY[_mode],
                validated_at = NOW()
            WHERE state_id = 'current';
        ELSE
            -- Same version, just add the mode if not already there
            IF NOT (_mode = ANY(_state.validated_modes)) THEN
                UPDATE hafbe_app.pipeline_validation_state
                SET validated_modes = array_append(validated_modes, _mode),
                    validated_at = NOW()
                WHERE state_id = 'current';
            END IF;
        END IF;
    END IF;
END
$$;

RESET ROLE;

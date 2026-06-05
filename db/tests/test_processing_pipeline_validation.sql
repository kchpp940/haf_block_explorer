/*
 * Regression test for processing pipeline validation.
 *
 * Tests:
 *   1. Initial state (last_validated_version = 0, not validated)
 *   2. Full validation succeeds and updates state
 *   3. is_pipeline_valid passes after successful validation
 *   4. Modifying processing_pipeline bumps version and invalidates runtime check
 *   5. Re-validation fixes the runtime check again
 *   6. TRUNCATE and re-insert also bumps version correctly
 *
 * Usage:
 *   psql $DB_URL -v ON_ERROR_STOP=on -f db/tests/test_processing_pipeline_validation.sql
 */

SET ROLE hafbe_owner;

-- ============================================================================
-- TEST HELPER FUNCTION
-- ============================================================================
-- Helper to check if a function raises expected exception
CREATE OR REPLACE FUNCTION test_expect_exception(
    _test_name TEXT,
    _sql TEXT,
    _expected_pattern TEXT
) RETURNS BOOLEAN
LANGUAGE 'plpgsql'
AS $$
BEGIN
    EXECUTE _sql;
    RAISE EXCEPTION 'Test "%" failed: expected exception matching "%" but none raised',
        _test_name, _expected_pattern;
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE _expected_pattern THEN
            RAISE NOTICE 'Test "%" passed: got expected exception', _test_name;
            RETURN TRUE;
        ELSE
            RAISE EXCEPTION 'Test "%" failed: expected "%" but got: %',
                _test_name, _expected_pattern, SQLERRM;
        END IF;
END $$;

-- ============================================================================
-- TEST 1: Initial state
-- ============================================================================
-- We expect is_pipeline_valid to fail because last_validated_version = 0
SELECT test_expect_exception(
    'is_pipeline_valid fails before any validation',
    'SELECT hafbe_app.is_pipeline_valid(''LIVE'')',
    '%has not been validated%'
);

-- ============================================================================
-- TEST 2: Full validation succeeds
-- ============================================================================
-- This should pass and update last_validated_version
DO $$
DECLARE
    _state RECORD;
BEGIN
    PERFORM hafbe_app.validate_processing_pipeline();

    SELECT * INTO _state FROM hafbe_app.pipeline_validation_state;

    IF _state.last_validated_version = 0 THEN
        RAISE EXCEPTION 'last_validated_version should be > 0 after validation';
    END IF;

    IF _state.last_validated_version != _state.current_pipeline_version THEN
        RAISE EXCEPTION 'last_validated_version should equal current_pipeline_version after validation';
    END IF;

    IF NOT ('MASSIVE' = ANY(_state.validated_modes)) THEN
        RAISE EXCEPTION 'MASSIVE should be in validated_modes after full validation';
    END IF;

    IF NOT ('LIVE' = ANY(_state.validated_modes)) THEN
        RAISE EXCEPTION 'LIVE should be in validated_modes after full validation';
    END IF;

    RAISE NOTICE 'Test "validate_processing_pipeline updates state" passed';
END $$;

-- ============================================================================
-- TEST 3: is_pipeline_valid passes after successful validation
-- ============================================================================
DO $$
BEGIN
    IF hafbe_app.is_pipeline_valid('LIVE') != TRUE THEN
        RAISE EXCEPTION 'is_pipeline_valid(''LIVE'') should return TRUE after validation';
    END IF;
    IF hafbe_app.is_pipeline_valid('MASSIVE') != TRUE THEN
        RAISE EXCEPTION 'is_pipeline_valid(''MASSIVE'') should return TRUE after validation';
    END IF;
    RAISE NOTICE 'Test "is_pipeline_valid passes after validation" passed';
END $$;

-- ============================================================================
-- TEST 4: Modifying processing_pipeline invalidates runtime check
-- ============================================================================
-- Insert a test processor (with a high order number to not interfere with existing ones)
DO $$
DECLARE
    _before_state RECORD;
    _after_state RECORD;
BEGIN
    SELECT * INTO _before_state FROM hafbe_app.pipeline_validation_state;

    -- Insert a dummy processor (won't actually be used since order is very high)
    INSERT INTO hafbe_app.processing_pipeline (
        processor_id, execution_order, processor_name,
        function_schema, function_name, function_signature,
        run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
    ) VALUES (
        'test_dummy', 999999, 'process_test_dummy',
        'hafbe_app', 'process_test_dummy', '(_from INT, _to INT)',
        FALSE, FALSE, '{}', '{}', 'RANGE',
        'Test processor for validation regression test'
    ) ON CONFLICT DO NOTHING;

    SELECT * INTO _after_state FROM hafbe_app.pipeline_validation_state;

    IF _after_state.current_pipeline_version <= _before_state.current_pipeline_version THEN
        RAISE EXCEPTION 'Version should have been bumped after INSERT: % -> %',
            _before_state.current_pipeline_version, _after_state.current_pipeline_version;
    END IF;

    IF _after_state.last_validated_version = _after_state.current_pipeline_version THEN
        RAISE EXCEPTION 'last_validated_version should NOT equal current after INSERT';
    END IF;

    RAISE NOTICE 'Test "INSERT bumps version" passed: % -> %',
        _before_state.current_pipeline_version, _after_state.current_pipeline_version;
END $$;

-- Now is_pipeline_valid should fail because version mismatch
SELECT test_expect_exception(
    'is_pipeline_valid fails after config change (version mismatch)',
    'SELECT hafbe_app.is_pipeline_valid(''LIVE'')',
    '%configuration has changed since last validation%'
);

-- ============================================================================
-- TEST 5: Re-validation fixes runtime check
-- ============================================================================
DO $$
DECLARE
    _state RECORD;
BEGIN
    -- Validation should fail because our dummy processor references a non-existent function
    RAISE NOTICE 'Expecting validation to fail due to dummy processor...';
    PERFORM hafbe_app.validate_processing_pipeline();
EXCEPTION
    WHEN OTHERS THEN
        IF SQLERRM LIKE '%Processor function not found: hafbe_app.process_test_dummy%' THEN
            RAISE NOTICE 'Got expected failure from dummy processor';
        ELSE
            RAISE EXCEPTION 'Unexpected error: %', SQLERRM;
        END IF;
END $$;

-- Remove the dummy processor and re-validate
DELETE FROM hafbe_app.processing_pipeline WHERE processor_id = 'test_dummy';

-- Version should be bumped again by DELETE
DO $$
DECLARE
    _state RECORD;
BEGIN
    SELECT * INTO _state FROM hafbe_app.pipeline_validation_state;
    IF _state.last_validated_version = _state.current_pipeline_version THEN
        RAISE EXCEPTION 'Version should still be mismatched after DELETE';
    END IF;
    RAISE NOTICE 'Test "DELETE also bumps version" passed';
END $$;

-- Now re-validate should succeed
DO $$
BEGIN
    PERFORM hafbe_app.validate_processing_pipeline();
    IF hafbe_app.is_pipeline_valid('LIVE') != TRUE THEN
        RAISE EXCEPTION 'is_pipeline_valid should pass after re-validation';
    END IF;
    RAISE NOTICE 'Test "re-validation fixes runtime check" passed';
END $$;

-- ============================================================================
-- TEST 6: TRUNCATE also bumps version
-- ============================================================================
-- First, save current configuration
CREATE TEMP TABLE _saved_pipeline AS
SELECT * FROM hafbe_app.processing_pipeline;

DO $$
DECLARE
    _before INT;
    _after INT;
BEGIN
    SELECT current_pipeline_version INTO _before
    FROM hafbe_app.pipeline_validation_state;

    TRUNCATE hafbe_app.processing_pipeline;

    SELECT current_pipeline_version INTO _after
    FROM hafbe_app.pipeline_validation_state;

    IF _after <= _before THEN
        RAISE EXCEPTION 'TRUNCATE should bump version: % -> %', _before, _after;
    END IF;

    RAISE NOTICE 'Test "TRUNCATE bumps version" passed: % -> %', _before, _after;
END $$;

-- Restore configuration
INSERT INTO hafbe_app.processing_pipeline
SELECT * FROM _saved_pipeline;
DROP TABLE _saved_pipeline;

-- Re-validate after restore
DO $$
BEGIN
    PERFORM hafbe_app.validate_processing_pipeline();
    IF hafbe_app.is_pipeline_valid('LIVE') != TRUE THEN
        RAISE EXCEPTION 'Should pass after restore + re-validate';
    END IF;
    RAISE NOTICE 'Test "restore + re-validate works" passed';
END $$;

-- ============================================================================
-- CLEANUP
-- ============================================================================
DROP FUNCTION test_expect_exception(TEXT, TEXT, TEXT);

RESET ROLE;

RAISE NOTICE '=';
RAISE NOTICE 'ALL TESTS PASSED';
RAISE NOTICE '=';

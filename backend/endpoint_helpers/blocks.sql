SET ROLE hafbe_owner;

/*
 * get_blocks_by_ops: Main orchestrator for block search API.
 *
 * Routes to the appropriate gatherer based on filter parameters, then enriches
 * the results using the shared blocksearch_build_result function.
 *
 * DESIGN:
 *   1. validate_block_search_params does ALL validation + parsing (single source of truth)
 *   2. Single CASE statement routes to the appropriate gatherer
 *   3. All gatherers return gatherer_result (intermediate type)
 *   4. blocksearch_build_result handles ALL enrichment (single point of truth)
 *
 * FILTER COMBINATIONS (8 total):
 *   1. no_filter       - No filters
 *   2. single_op       - Single operation type
 *   3. multi_op        - Multiple operation types
 *   4. key_value       - Single op + key-value filter
 *   5. account         - Account only
 *   6. account_op      - Account + single operation
 *   7. account_multi_op - Account + multiple operations
 *   8. account_key_value - Account + single op + key-value
 *
 * PARAMETERS:
 *   _operations  - Array of operation type IDs (NULL = no op filter)
 *   _account     - Account ID (NULL = no account filter)
 *   _order_is    - Sort direction ('asc' or 'desc')
 *   _from        - Starting block (NULL = genesis)
 *   _to          - Ending block (NULL = current head)
 *   _page        - Page number (1-based)
 *   _limit       - Page size
 *   _path_filter - Raw path-filter TEXT[] from API (NULL = no key filter)
 *
 * RETURNS: block_history with enriched block data
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_blocks_by_ops(
    _operations   INT[],
    _account      INT,
    _order_is     hafbe_backend.sort_direction,
    _from         INT,
    _to           INT,
    _page         INT,
    _limit        INT,
    _path_filter  TEXT[]
)
RETURNS hafbe_backend.block_history
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  __validated   hafbe_backend.blocksearch_validated_params;
  __gathered    hafbe_backend.gatherer_result;
BEGIN
  __validated := hafbe_backend.validate_block_search_params(_operations, _account, _path_filter);

  __gathered := CASE
    -- 1. No filter
    WHEN NOT __validated.filter_by_op AND NOT __validated.filter_by_account AND NOT __validated.filter_by_key THEN
      hafbe_backend.blocksearch_no_filter(_from, _to, _order_is, _page, _limit)

    -- 2. Single operation only
    WHEN __validated.filter_by_single AND NOT __validated.filter_by_account AND NOT __validated.filter_by_key THEN
      hafbe_backend.blocksearch_single_op(_operations[1], _from, _to, _order_is, _page, _limit)

    -- 3. Multiple operations only
    WHEN __validated.filter_by_op AND __validated.op_count > 1 AND NOT __validated.filter_by_account AND NOT __validated.filter_by_key THEN
      hafbe_backend.blocksearch_multi_op(_operations, _from, _to, _order_is, _page, _limit)

    -- 4. Single operation + key-value filter (no account)
    WHEN __validated.filter_by_single AND NOT __validated.filter_by_account AND __validated.filter_by_key THEN
      hafbe_backend.blocksearch_key_value(_operations[1], _from, _to, _order_is, _page, _limit, __validated.key_content, __validated.set_of_keys)

    -- 5. Account only
    WHEN NOT __validated.filter_by_op AND __validated.filter_by_account AND NOT __validated.filter_by_key THEN
      hafbe_backend.blocksearch_account(_account, _from, _to, _order_is, _page, _limit)

    -- 6. Account + single operation
    WHEN __validated.filter_by_single AND __validated.filter_by_account AND NOT __validated.filter_by_key THEN
      hafbe_backend.blocksearch_account_op(_operations[1], _account, _from, _to, _order_is, _page, _limit)

    -- 7. Account + multiple operations
    WHEN __validated.filter_by_op AND __validated.op_count > 1 AND __validated.filter_by_account AND NOT __validated.filter_by_key THEN
      hafbe_backend.blocksearch_account_multi_op(_operations, _account, _from, _to, _order_is, _page, _limit)

    -- 8. Account + single operation + key-value filter
    -- This is the ONLY path for account + key filter combination
    WHEN __validated.filter_by_single AND __validated.filter_by_account AND __validated.filter_by_key THEN
      hafbe_backend.blocksearch_account_key_value(_operations[1], _account, _from, _to, _order_is, _page, _limit, __validated.key_content, __validated.set_of_keys)

    ELSE
      NULL
  END;

  IF __gathered IS NULL THEN
    RAISE EXCEPTION 'Unhandled parameter combination: operation_types count=%, account=%, key_filter=%. This is a bug in validate_block_search_params.',
      __validated.op_count,
      CASE WHEN __validated.filter_by_account THEN 'yes' ELSE 'no' END,
      CASE WHEN __validated.filter_by_key THEN 'yes' ELSE 'no' END;
  END IF;

  RETURN hafbe_backend.blocksearch_build_result(__gathered, _order_is);
END
$$;

RESET ROLE;

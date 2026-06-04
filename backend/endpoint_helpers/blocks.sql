SET ROLE hafbe_owner;

/*
 * get_blocks_by_ops: Main orchestrator for block search API.
 *
 * Uses the COMPLETE routing pipeline from blocksearch_routing.sql.
 * This is intentionally a THIN wrapper - ALL logic lives in the routing module.
 *
 * PIPELINE (defined in blocksearch_routing.sql):
 *   1. Create context   - blocksearch_create_context()
 *   2. Invoke gatherer  - blocksearch_invoke_gatherer()
 *   3. Build result     - blocksearch_build_result()
 *
 * VALIDATION NOTE: Validation is performed in the ENDPOINT layer (get_block_by_op)
 * before calling this function. This function assumes inputs are already valid.
 *
 * PARAMETERS:
 *   _operations  - Array of operation type IDs (NULL = no op filter)
 *   _account     - Account ID (NULL = no account filter)
 *   _order_is    - Sort direction ('asc' or 'desc')
 *   _from        - Starting block (NULL = genesis)
 *   _to          - Ending block (NULL = current head)
 *   _page        - Page number (1-based)
 *   _limit       - Page size
 *   _key_content - Array of values to match for key-value filter
 *   _setof_keys  - JSON array of paths for key-value filter
 *
 * RETURNS: block_history with enriched block data
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_blocks_by_ops(
    _operations  INT[],
    _account     INT,
    _order_is    hafbe_backend.sort_direction,
    _from        INT,
    _to          INT,
    _page        INT,
    _limit       INT,
    _key_content TEXT[],
    _setof_keys  JSON
)
RETURNS hafbe_backend.block_history
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  __ctx hafbe_backend.blocksearch_context;
BEGIN
  -- Create complete routing context (ALL decisions made here)
  __ctx := hafbe_backend.blocksearch_create_context(
    _operations,
    _account,
    _from,
    _to,
    _order_is,
    _page,
    _limit,
    _key_content,
    _setof_keys
  );

  -- Execute the entire pipeline (gatherer + build result)
  RETURN hafbe_backend.blocksearch_execute(__ctx);
END
$$;

RESET ROLE;

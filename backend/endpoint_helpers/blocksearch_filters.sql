-- =============================================================================
-- Block Search Filters
-- =============================================================================
-- Consolidated from filtering_functions/*.sql
-- Contains all block search filter implementations
-- =============================================================================

SET ROLE hafbe_owner;

-- -----------------------------------------------------------------------------
-- Default filter (no operation filter)
-- From: default.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_no_filter: Gathers blocks without any operation filter.
 *
 * Returns all blocks in the specified range as candidates (no pagination).
 * Block count is calculated as (to - from + 1).
 *
 * NOTE: This gatherer uses SQL-level OFFSET + LIMIT for performance, but still
 * produces unpaginated candidates. The pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (not used directly, kept for interface consistency)
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier (not used directly, kept for interface consistency)
 *
 * RETURNS: blocksearch_candidates with all matching blocks (unpaginated)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_no_filter(
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __count               INT;
  __from                INT;
  __to                  INT;
  __candidate_blocks    hafbe_backend.gathered_block[];
BEGIN
  -- Get count and normalized range
  SELECT count_blocks, from_block, to_block
  INTO __count, __from, __to
  FROM hafbe_backend.blocksearch_no_filter_count(_from, _to, _current_block);

  -- Empty result case
  IF __count IS NULL OR __count = 0 THEN
    RETURN (
      '{}'::hafbe_backend.gathered_block[],
      0,
      __from,
      __to
    )::hafbe_backend.blocksearch_candidates;
  END IF;

  -- Gather ALL blocks with operations (no LIMIT yet - pagination handled by routing helper)
  SELECT array_agg(row ORDER BY
    (CASE WHEN _order_is = 'desc' THEN row.block_num ELSE NULL END) DESC,
    (CASE WHEN _order_is = 'asc' THEN row.block_num ELSE NULL END) ASC
  )
  INTO __candidate_blocks
  FROM (
    SELECT
      bv.num AS block_num,
      hafbe_backend.get_block_operation_aggregation(bv.num) AS operations
    FROM hive.blocks_view bv
    WHERE
      bv.num >= __from AND
      bv.num <= __to
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN bv.num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN bv.num ELSE NULL END) ASC
  ) row;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),  -- pre_grouped_count = total count for no_filter
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Single operation filter
-- From: by_operation.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_single_op: Gathers blocks containing a specific operation type.
 *
 * Uses the block_operations table for efficient filtering.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _operation      - Operation type ID to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_single_op(
    _operation      INT,
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from                INT;
  __to                  INT;
  __candidate_blocks    hafbe_backend.gathered_block[];
  __pre_grouped_count   INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, _current_block);

  WITH gather_operations AS MATERIALIZED (
    SELECT
      bo.block_num,
      bo.op_type_id,
      bo.op_count
    FROM hafbe_app.block_operations bo
    WHERE
      bo.op_type_id = _operation AND
      bo.block_num >= __from AND
      bo.block_num <= __to
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN bo.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN bo.block_num ELSE NULL END) ASC
    LIMIT (_max_page_count * _limit)
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      block_num,
      hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations
    FROM gather_operations
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Operation with key-value filter
-- From: by_operation_key_value.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_key_value: Gathers blocks with operations matching key-value filters.
 *
 * Filters operations by operation type and JSON key-value pairs.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _operation      - Operation type ID to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _key_content    - Array of values to match [val1, val2, val3]
 *   _setof_keys     - JSON array of paths [[path1], [path2], [path3]]
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_key_value(
    _operation      INT,
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _key_content    TEXT[],
    _setof_keys     JSON,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from                     INT;
  __to                       INT;
  __candidate_blocks         hafbe_backend.gathered_block[];
  __pre_grouped_count        INT;
  -- Keys must be declared separately for planner to use indexes
  _path1                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->0) OFFSET 1);
  _path2                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->1) OFFSET 1);
  _path3                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->2) OFFSET 1);
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, _current_block);

  WITH gather_operations AS MATERIALIZED (
    SELECT
      ov.block_num,
      ov.op_type_id
    FROM hive.operations_view ov
    WHERE
      ov.op_type_id = _operation AND
      ov.block_num <= __to AND
      ov.block_num >= __from AND
      ((_key_content[1] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC _path1) = _key_content[1]) AND
      ((_key_content[2] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC _path2) = _key_content[2]) AND
      ((_key_content[3] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC _path3) = _key_content[3])
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN ov.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN ov.block_num ELSE NULL END) ASC
    LIMIT (_max_page_count * _limit)
  ),
  group_by_type_and_block AS (
    SELECT
      block_num,
      op_type_id,
      COUNT(*) AS op_count
    FROM gather_operations
    GROUP BY block_num, op_type_id
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      block_num,
      hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations
    FROM group_by_type_and_block
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Multiple operations filter
-- From: by_multiple_operations.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_multi_op: Gathers blocks containing any of multiple operation types.
 *
 * Uses CROSS JOIN with find_blocks_with_op to efficiently search for multiple ops.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _operations     - Array of operation type IDs to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_multi_op(
    _operations     INT[],
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from                     INT;
  __to                       INT;
  __candidate_blocks         hafbe_backend.gathered_block[];
  __pre_grouped_count        INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, _current_block);

  WITH gather_operations AS (
    SELECT
      moh.block_num,
      moh.op_type_id,
      moh.op_count
    FROM
      unnest(_operations) AS op_type_id
    CROSS JOIN
      hafbe_backend.find_blocks_with_op(op_type_id, __from, __to, _order_is, _limit) moh
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      gb.block_num,
      array_agg((op_type_id, op_count)::hafbe_backend.block_operations) AS operations
    FROM gather_operations gb
    GROUP BY gb.block_num
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Account filter (all operations for account)
-- From: by_account.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_account: Gathers blocks containing operations for a specific account.
 *
 * Uses account_operations_view with sequence number range for efficient filtering.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _account_id     - Account ID to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account(
    _account_id     INT,
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET join_collapse_limit = 16
SET from_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from_seq                 INT;
  __to_seq                   INT;
  __from                     INT;
  __to                       INT;
  __candidate_blocks         hafbe_backend.gathered_block[];
  __pre_grouped_count        INT;
BEGIN
  SELECT from_block, to_block, from_seq, to_seq
  INTO __from, __to, __from_seq, __to_seq
  FROM hafbe_backend.blocksearch_account_range(_account_id, _from, _to, _current_block);

  WITH gather_operations AS MATERIALIZED (
    SELECT
      aov.block_num,
      aov.op_type_id
    FROM hive.account_operations_view aov
    WHERE
      aov.account_id = _account_id AND
      aov.account_op_seq_no <= __to_seq AND
      aov.account_op_seq_no >= __from_seq
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN aov.account_op_seq_no ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN aov.account_op_seq_no ELSE NULL END) ASC
    LIMIT (_max_page_count * _limit)
  ),
  group_by_type_and_block AS (
    SELECT
      block_num,
      op_type_id,
      COUNT(*) AS op_count
    FROM gather_operations
    GROUP BY block_num, op_type_id
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      block_num,
      array_agg((op_type_id, op_count)::hafbe_backend.block_operations) AS operations
    FROM group_by_type_and_block
    GROUP BY block_num
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Account + operation filter
-- From: by_account_operation.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_account_op: Gathers blocks with specific operation for a specific account.
 *
 * Filters by both account ID and operation type.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _operation      - Operation type ID to filter by
 *   _account_id     - Account ID to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_op(
    _operation      INT,
    _account_id     INT,
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET join_collapse_limit = 16
SET from_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from                     INT;
  __to                       INT;
  __candidate_blocks         hafbe_backend.gathered_block[];
  __pre_grouped_count        INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, _current_block);

  WITH gather_operations AS MATERIALIZED (
    SELECT
      aov.block_num,
      aov.op_type_id
    FROM hive.account_operations_view aov
    WHERE
      aov.op_type_id = _operation AND
      aov.account_id = _account_id AND
      aov.block_num >= __from AND
      aov.block_num <= __to
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN aov.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN aov.block_num ELSE NULL END) ASC
    LIMIT (_max_page_count * _limit)
  ),
  group_by_type_and_block AS (
    SELECT
      block_num,
      op_type_id,
      COUNT(*) AS op_count
    FROM gather_operations
    GROUP BY block_num, op_type_id
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      block_num,
      hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations
    FROM group_by_type_and_block
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Account + operation + key-value filter
-- From: by_account_operation_key_value.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_account_key_value: Gathers blocks with account + op + key-value filters.
 *
 * Filters by account ID, operation type, and JSON key-value pairs.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _operation      - Operation type ID to filter by
 *   _account_id     - Account ID to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _key_content    - Array of values to match [val1, val2, val3]
 *   _setof_keys     - JSON array of paths [[path1], [path2], [path3]]
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_key_value(
    _operation      INT,
    _account_id     INT,
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _key_content    TEXT[],
    _setof_keys     JSON,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from                     INT;
  __to                       INT;
  __candidate_blocks         hafbe_backend.gathered_block[];
  __pre_grouped_count        INT;
  -- Keys must be declared separately for planner to use indexes
  _path1                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->0) OFFSET 1);
  _path2                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->1) OFFSET 1);
  _path3                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->2) OFFSET 1);
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, _current_block);

  WITH source_ops AS (
    SELECT
      aov.block_num,
      aov.operation_id,
      aov.op_type_id
    FROM hive.account_operations_view aov
    WHERE
      aov.op_type_id = _operation AND
      aov.account_id = _account_id AND
      aov.block_num >= __from AND
      aov.block_num <= __to
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN aov.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN aov.block_num ELSE NULL END) ASC
  ),
  filter_by_key AS (
    SELECT
      ov.block_num,
      ov.id
    FROM hive.operations_view ov
    WHERE
      ov.op_type_id = _operation AND
      ov.block_num >= __from AND
      ov.block_num <= __to AND
      ((_key_content[1] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC _path1) = _key_content[1]) AND
      ((_key_content[2] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC _path2) = _key_content[2]) AND
      ((_key_content[3] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC _path3) = _key_content[3])
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN ov.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN ov.block_num ELSE NULL END) ASC
  ),
  gather_operations AS MATERIALIZED (
    SELECT
      so.block_num,
      so.op_type_id
    FROM source_ops so
    JOIN filter_by_key fbk ON so.operation_id = fbk.id
    LIMIT (_max_page_count * _limit)
  ),
  group_by_type_and_block AS (
    SELECT
      block_num,
      op_type_id,
      COUNT(*) AS op_count
    FROM gather_operations
    GROUP BY block_num, op_type_id
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      block_num,
      hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations
    FROM group_by_type_and_block
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

-- -----------------------------------------------------------------------------
-- Account + multiple operations filter
-- From: by_account_multi_operations.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_account_multi_op: Gathers blocks with multiple operations for an account.
 *
 * Uses CROSS JOIN with find_blocks_with_op_and_account for efficient multi-op search.
 * Returns candidates without pagination - pagination is handled by the routing helper.
 *
 * PARAMETERS:
 *   _operations     - Array of operation type IDs to filter by
 *   _account_id     - Account ID to filter by
 *   _from           - Starting block (NULL = genesis)
 *   _to             - Ending block (NULL = current head)
 *   _order_is       - Sort direction ('asc' or 'desc')
 *   _limit          - Page size (used for saturation limiting)
 *   _current_block  - Current head block number
 *   _max_page_count - Max page multiplier for limiting gathered rows
 *
 * RETURNS: blocksearch_candidates with candidate blocks and pre_grouped_count
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_multi_op(
    _operations     INT[],
    _account_id     INT,
    _from           INT,
    _to             INT,
    _order_is       hafbe_backend.sort_direction,
    _limit          INT,
    _current_block  INT,
    _max_page_count INT
)
RETURNS hafbe_backend.blocksearch_candidates
LANGUAGE 'plpgsql' STABLE
SET join_collapse_limit = 16
SET from_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __from                     INT;
  __to                       INT;
  __candidate_blocks         hafbe_backend.gathered_block[];
  __pre_grouped_count        INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, _current_block);

  WITH gather_operations AS MATERIALIZED (
    SELECT
      moh.block_num,
      moh.op_type_id
    FROM
      unnest(_operations) AS op_type_id
    CROSS JOIN
      hafbe_backend.find_blocks_with_op_and_account(op_type_id, _account_id, __from, __to, _order_is, _limit) moh
  ),
  group_by_type_and_block AS (
    SELECT
      block_num,
      op_type_id,
      COUNT(*) AS op_count
    FROM gather_operations
    GROUP BY block_num, op_type_id
  ),
  eliminate_duplicate_blocks AS MATERIALIZED (
    SELECT
      block_num,
      array_agg((op_type_id, op_count)::hafbe_backend.block_operations) AS operations
    FROM group_by_type_and_block
    GROUP BY block_num
  )
  SELECT
    array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
      (CASE WHEN _order_is = 'desc' THEN block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN block_num ELSE NULL END) ASC
    ),
    (SELECT COUNT(*) FROM gather_operations),
    __from,
    __to
  INTO __candidate_blocks, __pre_grouped_count, __from, __to;

  RETURN (
    COALESCE(__candidate_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__pre_grouped_count, 0),
    __from,
    __to
  )::hafbe_backend.blocksearch_candidates;
END
$$;

RESET ROLE;

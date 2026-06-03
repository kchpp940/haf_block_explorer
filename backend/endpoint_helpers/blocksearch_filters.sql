-- =============================================================================
-- Block Search Filters
-- =============================================================================
-- Consolidated from filtering_functions/*.sql
-- Contains all block search filter implementations
-- =============================================================================
--
-- STABLE SORTING CONVENTION:
-- All gatherers use stable composite sort keys to avoid skipping or
-- duplicating results during pagination:
--
--   - Non-account queries: block_num + operation_id
--   - Account queries: account_op_seq_no
--
-- BOUNDARY CONDITION PATTERN:
--   DESC: (key_col1, key_col2) < (cursor.val1, cursor.val2)
--   ASC:  (key_col1, key_col2) > (cursor.val1, cursor.val2)
--
-- NEXT_CURSOR GENERATION:
--   Always use the LIMIT+1 row's key values (not the last returned row)
--   to ensure correct resumption point.
-- =============================================================================

SET ROLE hafbe_owner;

-- -----------------------------------------------------------------------------
-- Default filter (no operation filter)
-- From: default.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_no_filter: Gathers blocks without any operation filter.
 *
 * Returns all blocks in the specified range using efficient SQL-level pagination.
 * This is the simplest gatherer - block count is calculated as (to - from + 1).
 *
 * Uses block_num + max(operation_id) within block as stable sort key.
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _from        - Starting block (NULL = genesis)
 *   _to          - Ending block (NULL = current head)
 *   _order_is    - Sort direction ('asc' or 'desc')
 *   _page        - Page number (1-based, used if cursor is NULL)
 *   _limit       - Page size
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks and operations, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_no_filter(
    _from        INT,
    _to          INT,
    _order_is    hafbe_backend.sort_direction,
    _page        INT,
    _limit       INT,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __count               INT;
  __from                INT;
  __to                  INT;
  __total_pages         INT;
  __offset              INT;
  __limit_size          INT;
  __blocks              hafbe_backend.gathered_block[];
  __cursor_boundary     TEXT := hafbe_backend.blocksearch_get_cursor_boundary(_cursor, 'bv.num');
  __has_more            BOOLEAN := FALSE;
  __last_block_num      INT;
  __last_op_id          BIGINT;
  __next_cursor         TEXT;
  __cursor_state        hafbe_backend.blocksearch_cursor;
BEGIN
  SELECT count_blocks, from_block, to_block
  INTO __count, __from, __to
  FROM hafbe_backend.blocksearch_no_filter_count(_from, _to, __hafbe_current_block);

  IF _cursor IS NULL THEN
    SELECT total_pages, offset_filter, limit_filter
    INTO __total_pages, __offset, __limit_size
    FROM hafbe_backend.blocksearch_calculate_pages(__count, _page, _order_is, _limit);
  ELSE
    __limit_size := _limit;
    __offset := 0;
    SELECT total_pages
    INTO __total_pages
    FROM hafbe_backend.blocksearch_calculate_pages(__count, NULL, _order_is, _limit);
  END IF;

  IF __total_pages = 0 THEN
    RETURN (
      '{}'::hafbe_backend.gathered_block[],
      __count,
      __total_pages,
      NULL::INT,
      __count,
      __count,
      __from,
      __to,
      NULL::TEXT,
      NULL::INT,
      NULL::BIGINT,
      NULL::INT,
      FALSE
    )::hafbe_backend.gatherer_result;
  END IF;

  EXECUTE format('
    WITH block_ops AS MATERIALIZED (
      SELECT
        bv.num AS block_num,
        MAX(ov.id) AS max_op_id,
        hafbe_backend.get_block_operation_aggregation(bv.num) AS operations
      FROM hive.blocks_view bv
      LEFT JOIN hive.operations_view ov ON ov.block_num = bv.num
      WHERE
        bv.num >= %L AND
        bv.num <= %L AND
        %s AND
        (%L = ''desc'' OR bv.num >= %L + %L) AND
        (%L = ''asc'' OR bv.num <= %L - %L)
      GROUP BY bv.num
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN bv.num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN bv.num ELSE NULL END) ASC
      LIMIT %L
    ),
    last_op AS (
      SELECT max_op_id FROM block_ops ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    )
    SELECT
      array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      ),
      (SELECT max_op_id FROM last_op)
    FROM block_ops
  ', __from, __to, __cursor_boundary,
     _order_is, __from, __offset, _order_is, __to, __offset,
     _order_is, _order_is, __limit_size + 1,
     _order_is, _order_is,
     _order_is, _order_is)
  INTO __blocks, __last_op_id;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) = __limit_size + 1 THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 THEN
    IF _order_is = 'desc' THEN
      __last_block_num := __blocks[array_length(__blocks, 1)].block_num;
    ELSE
      __last_block_num := __blocks[array_length(__blocks, 1)].block_num;
    END IF;

    IF __has_more THEN
      __cursor_state := (
        __last_block_num,
        __last_op_id,
        _order_is,
        NULL::INT,
        _filter_hash,
        2
      )::hafbe_backend.blocksearch_cursor;
      __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
    END IF;
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    NULL::INT,
    __count,
    __count,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    NULL::INT,
    __has_more
  )::hafbe_backend.gatherer_result;
END
$$;

-- -----------------------------------------------------------------------------
-- Single operation filter
-- From: by_operation.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_single_op: Gathers blocks containing a specific operation type.
 *
 * Uses the operations_view with block_num + operation_id as stable sort key
 * to avoid skipping/duplicating when multiple operations exist in the same block.
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _operation   - Operation type ID to filter by
 *   _from        - Starting block (NULL = genesis)
 *   _to          - Ending block (NULL = current head)
 *   _order_is    - Sort direction ('asc' or 'desc')
 *   _page        - Page number (1-based, used if cursor is NULL)
 *   _limit       - Page size
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks matching the operation, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_single_op(
    _operation   INT,
    _from        INT,
    _to          INT,
    _order_is    hafbe_backend.sort_direction,
    _page        INT,
    _limit       INT,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count      INT := 10;
  __min_block_num       INT;
  __count               INT;
  __from                INT;
  __to                  INT;
  __total_pages         INT;
  __blocks              hafbe_backend.gathered_block[];
  __cursor_boundary     TEXT := hafbe_backend.blocksearch_get_stable_cursor_boundary(_cursor, 'ov.block_num', 'ov.id');
  __has_more            BOOLEAN := FALSE;
  __last_block_num      INT;
  __last_op_id          BIGINT;
  __next_cursor         TEXT;
  __cursor_state        hafbe_backend.blocksearch_cursor;
  __limit_size          INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH gather_operations AS MATERIALIZED (
      SELECT
        ov.block_num,
        ov.id AS operation_id,
        ov.op_type_id
      FROM hive.operations_view ov
      WHERE
        ov.op_type_id = %L AND
        ov.block_num >= %L AND
        ov.block_num <= %L AND
        %s
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN ov.block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''desc'' THEN ov.id ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN ov.block_num ELSE NULL END) ASC,
        (CASE WHEN %L = ''asc'' THEN ov.id ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        block_num,
        hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations,
        max_op_id
      FROM group_by_type_and_block
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    last_op_info AS (
      SELECT block_num, max_op_id FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT block_num FROM last_op_info),
      (SELECT max_op_id FROM last_op_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _operation, __from, __to, __cursor_boundary,
     _order_is, _order_is, _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __last_block_num, __last_op_id, __blocks;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      NULL::INT,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    NULL::INT,
    __has_more
  )::hafbe_backend.gatherer_result;
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
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _operation   - Operation type ID to filter by
 *   _from        - Starting block (NULL = genesis)
 *   _to          - Ending block (NULL = current head)
 *   _order_is    - Sort direction ('asc' or 'desc')
 *   _page        - Page number (1-based, used if cursor is NULL)
 *   _limit       - Page size
 *   _key_content - Array of values to match [val1, val2, val3]
 *   _setof_keys  - JSON array of paths [[path1], [path2], [path3]]
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks matching the filter, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_key_value(
    _operation   INT,
    _from        INT,
    _to          INT,
    _order_is    hafbe_backend.sort_direction,
    _page        INT,
    _limit       INT,
    _key_content TEXT[],
    _setof_keys  JSON,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block      INT    := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count           INT    := 10;
  __min_block_num            INT;
  __count_pre_grouped_blocks INT;
  __count                    INT;
  __from                     INT;
  __to                       INT;
  __total_pages              INT;
  __blocks                   hafbe_backend.gathered_block[];
  __cursor_boundary          TEXT   := hafbe_backend.blocksearch_get_stable_cursor_boundary(_cursor, 'ov.block_num', 'ov.id');
  __has_more                 BOOLEAN := FALSE;
  __last_block_num           INT;
  __last_op_id               BIGINT;
  __next_cursor              TEXT;
  __cursor_state             hafbe_backend.blocksearch_cursor;
  __limit_size               INT;
  -- Keys must be declared separately for planner to use indexes
  _path1                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->0) OFFSET 1);
  _path2                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->1) OFFSET 1);
  _path3                     TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->2) OFFSET 1);
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH gather_operations AS MATERIALIZED (
      SELECT
        ov.block_num,
        ov.id AS operation_id,
        ov.op_type_id
      FROM hive.operations_view ov
      WHERE
        ov.op_type_id = %L AND
        ov.block_num <= %L AND
        ov.block_num >= %L AND
        %s AND
        ((%L::TEXT[] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC %L::TEXT[]) = %L) AND
        ((%L::TEXT[] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC %L::TEXT[]) = %L) AND
        ((%L::TEXT[] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC %L::TEXT[]) = %L)
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN ov.block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''desc'' THEN ov.id ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN ov.block_num ELSE NULL END) ASC,
        (CASE WHEN %L = ''asc'' THEN ov.id ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        block_num,
        hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations,
        max_op_id
      FROM group_by_type_and_block
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    count_pre_grouped_blocks AS (
      SELECT COUNT(*) AS count
      FROM gather_operations
    ),
    last_op_info AS (
      SELECT block_num, max_op_id FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT count FROM count_pre_grouped_blocks),
      (SELECT block_num FROM last_op_info),
      (SELECT max_op_id FROM last_op_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _operation, __to, __from, __cursor_boundary,
     _key_content[1], _path1, _key_content[1],
     _key_content[2], _path2, _key_content[2],
     _key_content[3], _path3, _key_content[3],
     _order_is, _order_is, _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __count_pre_grouped_blocks, __last_block_num, __last_op_id, __blocks;

  -- Check if we have more results
  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  -- Generate next cursor
  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      NULL::INT,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count_pre_grouped_blocks,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    NULL::INT,
    __has_more
  )::hafbe_backend.gatherer_result;
END
$$;

-- -----------------------------------------------------------------------------
-- Multiple operations filter
-- From: by_multiple_operations.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_multi_op: Gathers blocks containing any of multiple operation types.
 *
 * Uses direct query on block_operations table with IN clause for efficient multi-op search.
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _operations - Array of operation type IDs to filter by
 *   _from       - Starting block (NULL = genesis)
 *   _to         - Ending block (NULL = current head)
 *   _order_is   - Sort direction ('asc' or 'desc')
 *   _page       - Page number (1-based, used if cursor is NULL)
 *   _limit      - Page size
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks matching any operation, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_multi_op(
    _operations INT[],
    _from       INT,
    _to         INT,
    _order_is   hafbe_backend.sort_direction,
    _page       INT,
    _limit      INT,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block      INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count           INT := array_length(_operations, 1);
  __min_block_num            INT;
  __count_pre_grouped_blocks INT;
  __count                    INT;
  __from                     INT;
  __to                       INT;
  __total_pages              INT;
  __blocks                   hafbe_backend.gathered_block[];
  __cursor_boundary          TEXT    := hafbe_backend.blocksearch_get_stable_cursor_boundary(_cursor, 'ov.block_num', 'ov.id');
  __has_more                 BOOLEAN := FALSE;
  __last_block_num           INT;
  __last_op_id               BIGINT;
  __next_cursor              TEXT;
  __cursor_state             hafbe_backend.blocksearch_cursor;
  __limit_size               INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH gather_operations AS MATERIALIZED (
      SELECT
        ov.block_num,
        ov.id AS operation_id,
        ov.op_type_id
      FROM hive.operations_view ov
      WHERE
        ov.op_type_id = ANY(%L::INT[]) AND
        ov.block_num >= %L AND
        ov.block_num <= %L AND
        %s
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN ov.block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''desc'' THEN ov.id ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN ov.block_num ELSE NULL END) ASC,
        (CASE WHEN %L = ''asc'' THEN ov.id ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        gb.block_num,
        array_agg((op_type_id, op_count)::hafbe_backend.block_operations) AS operations,
        MAX(max_op_id) AS max_op_id
      FROM group_by_type_and_block gb
      GROUP BY gb.block_num
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    count_pre_grouped_blocks AS (
      SELECT COUNT(*) AS count
      FROM gather_operations
    ),
    last_op_info AS (
      SELECT block_num, max_op_id FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT count FROM count_pre_grouped_blocks),
      (SELECT block_num FROM last_op_info),
      (SELECT max_op_id FROM last_op_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _operations, __from, __to, __cursor_boundary,
     _order_is, _order_is, _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __count_pre_grouped_blocks, __last_block_num, __last_op_id, __blocks;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      NULL::INT,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count_pre_grouped_blocks,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    NULL::INT,
    __has_more
  )::hafbe_backend.gatherer_result;
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
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _account_id - Account ID to filter by
 *   _from       - Starting block (NULL = genesis)
 *   _to         - Ending block (NULL = current head)
 *   _order_is   - Sort direction ('asc' or 'desc')
 *   _page       - Page number (1-based, used if cursor is NULL)
 *   _limit      - Page size
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks for the account, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account(
    _account_id INT,
    _from       INT,
    _to         INT,
    _order_is   hafbe_backend.sort_direction,
    _page       INT,
    _limit      INT,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET join_collapse_limit = 16
SET from_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block        INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count             INT := 10;
  __from_seq                   INT;
  __to_seq                     INT;
  __min_block_num              INT;
  __count_pre_grouped_blocks   INT;
  __count                      INT;
  __from                       INT;
  __to                         INT;
  __total_pages                INT;
  __blocks                     hafbe_backend.gathered_block[];
  __cursor_boundary            TEXT    := hafbe_backend.blocksearch_get_cursor_boundary(_cursor, 'aov.block_num');
  __account_cursor_boundary    TEXT    := hafbe_backend.blocksearch_get_account_cursor_boundary(_cursor, 'aov.account_op_seq_no');
  __has_more                   BOOLEAN := FALSE;
  __last_block_num             INT;
  __last_op_id                 BIGINT;
  __last_account_seq           INT;
  __next_cursor                TEXT;
  __cursor_state               hafbe_backend.blocksearch_cursor;
  __limit_size                 INT;
BEGIN
  SELECT from_block, to_block, from_seq, to_seq
  INTO __from, __to, __from_seq, __to_seq
  FROM hafbe_backend.blocksearch_account_range(_account_id, _from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH gather_operations AS MATERIALIZED (
      SELECT
        aov.block_num,
        aov.operation_id,
        aov.op_type_id,
        aov.account_op_seq_no
      FROM hive.account_operations_view aov
      WHERE
        aov.account_id = %L AND
        aov.account_op_seq_no <= %L AND
        aov.account_op_seq_no >= %L AND
        %s AND
        %s
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN aov.account_op_seq_no ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN aov.account_op_seq_no ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id,
        MAX(account_op_seq_no) AS max_account_seq
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        block_num,
        array_agg((op_type_id, op_count)::hafbe_backend.block_operations) AS operations,
        MAX(max_op_id) AS max_op_id,
        MAX(max_account_seq) AS max_account_seq
      FROM group_by_type_and_block
      GROUP BY block_num
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    count_pre_grouped_blocks AS (
      SELECT COUNT(*) AS count
      FROM gather_operations
    ),
    last_seq_info AS (
      SELECT block_num, max_op_id, max_account_seq FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id, max_account_seq
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT count FROM count_pre_grouped_blocks),
      (SELECT block_num FROM last_seq_info),
      (SELECT max_op_id FROM last_seq_info),
      (SELECT max_account_seq FROM last_seq_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _account_id, __to_seq, __from_seq, __cursor_boundary, __account_cursor_boundary,
     _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __count_pre_grouped_blocks, __last_block_num, __last_op_id, __last_account_seq, __blocks;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      __last_account_seq,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count_pre_grouped_blocks,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    __last_account_seq,
    __has_more
  )::hafbe_backend.gatherer_result;
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
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _operation  - Operation type ID to filter by
 *   _account_id - Account ID to filter by
 *   _from       - Starting block (NULL = genesis)
 *   _to         - Ending block (NULL = current head)
 *   _order_is   - Sort direction ('asc' or 'desc')
 *   _page       - Page number (1-based, used if cursor is NULL)
 *   _limit      - Page size
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks matching both filters, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_op(
    _operation  INT,
    _account_id INT,
    _from       INT,
    _to         INT,
    _order_is   hafbe_backend.sort_direction,
    _page       INT,
    _limit      INT,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET join_collapse_limit = 16
SET from_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block        INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count             INT := 10;
  __min_block_num              INT;
  __count_pre_grouped_blocks   INT;
  __count                      INT;
  __from                       INT;
  __to                         INT;
  __total_pages                INT;
  __blocks                     hafbe_backend.gathered_block[];
  __cursor_boundary            TEXT    := hafbe_backend.blocksearch_get_cursor_boundary(_cursor, 'aov.block_num');
  __account_cursor_boundary    TEXT    := hafbe_backend.blocksearch_get_account_cursor_boundary(_cursor, 'aov.account_op_seq_no');
  __has_more                   BOOLEAN := FALSE;
  __last_block_num             INT;
  __last_op_id                 BIGINT;
  __last_account_seq           INT;
  __next_cursor                TEXT;
  __cursor_state               hafbe_backend.blocksearch_cursor;
  __limit_size                 INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH gather_operations AS MATERIALIZED (
      SELECT
        aov.block_num,
        aov.operation_id,
        aov.op_type_id,
        aov.account_op_seq_no
      FROM hive.account_operations_view aov
      WHERE
        aov.op_type_id = %L AND
        aov.account_id = %L AND
        aov.block_num >= %L AND
        aov.block_num <= %L AND
        %s AND
        %s
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN aov.account_op_seq_no ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN aov.account_op_seq_no ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id,
        MAX(account_op_seq_no) AS max_account_seq
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        block_num,
        hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations,
        MAX(max_op_id) AS max_op_id,
        MAX(max_account_seq) AS max_account_seq
      FROM group_by_type_and_block
      GROUP BY block_num
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    count_pre_grouped_blocks AS (
      SELECT COUNT(*) AS count
      FROM gather_operations
    ),
    last_seq_info AS (
      SELECT block_num, max_op_id, max_account_seq FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id, max_account_seq
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT count FROM count_pre_grouped_blocks),
      (SELECT block_num FROM last_seq_info),
      (SELECT max_op_id FROM last_seq_info),
      (SELECT max_account_seq FROM last_seq_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _operation, _account_id, __from, __to, __cursor_boundary, __account_cursor_boundary,
     _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __count_pre_grouped_blocks, __last_block_num, __last_op_id, __last_account_seq, __blocks;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      __last_account_seq,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count_pre_grouped_blocks,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    __last_account_seq,
    __has_more
  )::hafbe_backend.gatherer_result;
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
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _operation   - Operation type ID to filter by
 *   _account_id  - Account ID to filter by
 *   _from        - Starting block (NULL = genesis)
 *   _to          - Ending block (NULL = current head)
 *   _order_is    - Sort direction ('asc' or 'desc')
 *   _page        - Page number (1-based, used if cursor is NULL)
 *   _limit       - Page size
 *   _key_content - Array of values to match [val1, val2, val3]
 *   _setof_keys  - JSON array of paths [[path1], [path2], [path3]]
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks matching all filters, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_key_value(
    _operation   INT,
    _account_id  INT,
    _from        INT,
    _to          INT,
    _order_is    hafbe_backend.sort_direction,
    _page        INT,
    _limit       INT,
    _key_content TEXT[],
    _setof_keys  JSON,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block        INT    := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count             INT    := 10;
  __min_block_num              INT;
  __count_pre_grouped_blocks   INT;
  __count                      INT;
  __from                       INT;
  __to                         INT;
  __total_pages                INT;
  __blocks                     hafbe_backend.gathered_block[];
  __cursor_boundary            TEXT    := hafbe_backend.blocksearch_get_cursor_boundary(_cursor, 'aov.block_num');
  __account_cursor_boundary    TEXT    := hafbe_backend.blocksearch_get_account_cursor_boundary(_cursor, 'aov.account_op_seq_no');
  __ov_cursor_boundary         TEXT    := hafbe_backend.blocksearch_get_stable_cursor_boundary(_cursor, 'ov.block_num', 'ov.id');
  __has_more                   BOOLEAN := FALSE;
  __last_block_num             INT;
  __last_op_id                 BIGINT;
  __last_account_seq           INT;
  __next_cursor                TEXT;
  __cursor_state               hafbe_backend.blocksearch_cursor;
  __limit_size                 INT;
  -- Keys must be declared separately for planner to use indexes
  _path1                       TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->0) OFFSET 1);
  _path2                       TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->1) OFFSET 1);
  _path3                       TEXT[] := ARRAY(SELECT json_array_elements_text(_setof_keys->2) OFFSET 1);
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH source_ops AS MATERIALIZED (
      SELECT
        aov.block_num,
        aov.operation_id,
        aov.op_type_id,
        aov.account_op_seq_no
      FROM hive.account_operations_view aov
      WHERE
        aov.op_type_id = %L AND
        aov.account_id = %L AND
        aov.block_num >= %L AND
        aov.block_num <= %L AND
        %s AND
        %s
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN aov.account_op_seq_no ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN aov.account_op_seq_no ELSE NULL END) ASC
    ),
    filter_by_key AS (
      SELECT
        ov.block_num,
        ov.id
      FROM hive.operations_view ov
      WHERE
        ov.op_type_id = %L AND
        ov.block_num >= %L AND
        ov.block_num <= %L AND
        %s AND
        ((%L::TEXT[] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC %L::TEXT[]) = %L) AND
        ((%L::TEXT[] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC %L::TEXT[]) = %L) AND
        ((%L::TEXT[] IS NULL) OR jsonb_extract_path_text(ov.body_value, VARIADIC %L::TEXT[]) = %L)
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN ov.block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''desc'' THEN ov.id ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN ov.block_num ELSE NULL END) ASC,
        (CASE WHEN %L = ''asc'' THEN ov.id ELSE NULL END) ASC
    ),
    gather_operations AS MATERIALIZED (
      SELECT
        so.block_num,
        so.operation_id,
        so.op_type_id,
        so.account_op_seq_no
      FROM source_ops so
      JOIN filter_by_key fbk ON so.operation_id = fbk.id
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN so.account_op_seq_no ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN so.account_op_seq_no ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id,
        MAX(account_op_seq_no) AS max_account_seq
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        block_num,
        hafbe_backend.build_json_for_single_operation(op_type_id, op_count::INT) AS operations,
        MAX(max_op_id) AS max_op_id,
        MAX(max_account_seq) AS max_account_seq
      FROM group_by_type_and_block
      GROUP BY block_num
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    count_pre_grouped_blocks AS (
      SELECT COUNT(*) AS count
      FROM gather_operations
    ),
    last_seq_info AS (
      SELECT block_num, max_op_id, max_account_seq FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id, max_account_seq
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT count FROM count_pre_grouped_blocks),
      (SELECT block_num FROM last_seq_info),
      (SELECT max_op_id FROM last_seq_info),
      (SELECT max_account_seq FROM last_seq_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _operation, _account_id, __from, __to, __cursor_boundary, __account_cursor_boundary,
     _order_is, _order_is,
     _operation, __from, __to, __ov_cursor_boundary,
     _key_content[1], _path1, _key_content[1],
     _key_content[2], _path2, _key_content[2],
     _key_content[3], _path3, _key_content[3],
     _order_is, _order_is, _order_is, _order_is,
     _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __count_pre_grouped_blocks, __last_block_num, __last_op_id, __last_account_seq, __blocks;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      __last_account_seq,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count_pre_grouped_blocks,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    __last_account_seq,
    __has_more
  )::hafbe_backend.gatherer_result;
END
$$;

-- -----------------------------------------------------------------------------
-- Account + multiple operations filter
-- From: by_account_multi_operations.sql
-- -----------------------------------------------------------------------------

/*
 * blocksearch_account_multi_op: Gathers blocks with multiple operations for an account.
 *
 * Uses direct query on account_operations_view with IN clause for efficient multi-op search.
 *
 * Supports both page-based and cursor-based pagination. When cursor is provided,
 * it takes precedence over page parameters for better performance with deep pagination.
 *
 * PARAMETERS:
 *   _operations - Array of operation type IDs to filter by
 *   _account_id - Account ID to filter by
 *   _from       - Starting block (NULL = genesis)
 *   _to         - Ending block (NULL = current head)
 *   _order_is   - Sort direction ('asc' or 'desc')
 *   _page       - Page number (1-based, used if cursor is NULL)
 *   _limit      - Page size
 *   _cursor      - Decoded cursor state (NULL for first page)
 *   _filter_hash - Hash of filter parameters for cursor encoding
 *
 * RETURNS: gatherer_result with paginated blocks matching account and any operation, including next_cursor
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_multi_op(
    _operations INT[],
    _account_id INT,
    _from       INT,
    _to         INT,
    _order_is   hafbe_backend.sort_direction,
    _page       INT,
    _limit      INT,
    _cursor      hafbe_backend.blocksearch_cursor = NULL,
    _filter_hash TEXT = NULL
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql' STABLE
SET join_collapse_limit = 16
SET from_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __hafbe_current_block        INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __max_page_count             INT := array_length(_operations, 1);
  __min_block_num              INT;
  __count_pre_grouped_blocks   INT;
  __count                      INT;
  __from                       INT;
  __to                         INT;
  __total_pages                INT;
  __blocks                     hafbe_backend.gathered_block[];
  __cursor_boundary            TEXT    := hafbe_backend.blocksearch_get_cursor_boundary(_cursor, 'aov.block_num');
  __account_cursor_boundary    TEXT    := hafbe_backend.blocksearch_get_account_cursor_boundary(_cursor, 'aov.account_op_seq_no');
  __has_more                   BOOLEAN := FALSE;
  __last_block_num             INT;
  __last_op_id                 BIGINT;
  __last_account_seq           INT;
  __next_cursor                TEXT;
  __cursor_state               hafbe_backend.blocksearch_cursor;
  __limit_size                 INT;
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from, _to, __hafbe_current_block);

  __limit_size := _limit;

  EXECUTE format('
    WITH gather_operations AS MATERIALIZED (
      SELECT
        aov.block_num,
        aov.operation_id,
        aov.op_type_id,
        aov.account_op_seq_no
      FROM hive.account_operations_view aov
      WHERE
        aov.op_type_id = ANY(%L::INT[]) AND
        aov.account_id = %L AND
        aov.block_num >= %L AND
        aov.block_num <= %L AND
        %s AND
        %s
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN aov.account_op_seq_no ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN aov.account_op_seq_no ELSE NULL END) ASC
      LIMIT %L
    ),
    group_by_type_and_block AS (
      SELECT
        block_num,
        op_type_id,
        COUNT(*) AS op_count,
        MAX(operation_id) AS max_op_id,
        MAX(account_op_seq_no) AS max_account_seq
      FROM gather_operations
      GROUP BY block_num, op_type_id
    ),
    eliminate_duplicate_blocks AS MATERIALIZED (
      SELECT
        gb.block_num,
        array_agg((op_type_id, op_count)::hafbe_backend.block_operations) AS operations,
        MAX(max_op_id) AS max_op_id,
        MAX(max_account_seq) AS max_account_seq
      FROM group_by_type_and_block gb
      GROUP BY gb.block_num
    ),
    min_block_num AS (
      SELECT MIN(block_num) AS block_num
      FROM eliminate_duplicate_blocks
    ),
    count_blocks AS MATERIALIZED (
      SELECT COUNT(*) AS count
      FROM eliminate_duplicate_blocks
    ),
    count_pre_grouped_blocks AS (
      SELECT COUNT(*) AS count
      FROM gather_operations
    ),
    last_seq_info AS (
      SELECT block_num, max_op_id, max_account_seq FROM eliminate_duplicate_blocks ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      LIMIT 1
    ),
    calculate_pages AS MATERIALIZED (
      SELECT total_pages, offset_filter, limit_filter
      FROM hafbe_backend.blocksearch_calculate_pages(
        (SELECT count FROM count_blocks)::INT,
        %L,
        %L,
        %L
      )
    ),
    filter_page AS MATERIALIZED (
      SELECT block_num, operations, max_op_id, max_account_seq
      FROM eliminate_duplicate_blocks
      ORDER BY
        (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
        (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
      OFFSET (SELECT CASE WHEN %L IS NOT NULL THEN 0 ELSE offset_filter END FROM calculate_pages)
      LIMIT (SELECT CASE WHEN %L IS NOT NULL THEN %L + 1 ELSE limit_filter + 1 END FROM calculate_pages)
    )
    SELECT
      (SELECT count FROM count_blocks),
      (SELECT total_pages FROM calculate_pages),
      (SELECT block_num FROM min_block_num),
      (SELECT count FROM count_pre_grouped_blocks),
      (SELECT block_num FROM last_seq_info),
      (SELECT max_op_id FROM last_seq_info),
      (SELECT max_account_seq FROM last_seq_info),
      (
        SELECT array_agg((block_num, operations)::hafbe_backend.gathered_block ORDER BY
          (CASE WHEN %L = ''desc'' THEN block_num ELSE NULL END) DESC,
          (CASE WHEN %L = ''asc'' THEN block_num ELSE NULL END) ASC
        )
        FROM filter_page
      )
  ', _operations, _account_id, __from, __to, __cursor_boundary, __account_cursor_boundary,
     _order_is, _order_is,
     CASE WHEN _cursor IS NULL THEN __max_page_count * _limit ELSE __limit_size + 1 END,
     _order_is, _order_is,
     _page, _order_is, _limit,
     _order_is, _order_is,
     _cursor, _cursor, __limit_size,
     _order_is, _order_is)
  INTO __count, __total_pages, __min_block_num, __count_pre_grouped_blocks, __last_block_num, __last_op_id, __last_account_seq, __blocks;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > __limit_size THEN
    __has_more := TRUE;
    __blocks := __blocks[1:__limit_size];
  END IF;

  IF __blocks IS NOT NULL AND array_length(__blocks, 1) > 0 AND __has_more THEN
    __cursor_state := (
      __last_block_num,
      __last_op_id,
      _order_is,
      __last_account_seq,
      _filter_hash,
      2
    )::hafbe_backend.blocksearch_cursor;
    __next_cursor := hafbe_backend.blocksearch_encode_cursor(__cursor_state);
  END IF;

  RETURN (
    COALESCE(__blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    __count_pre_grouped_blocks,
    __max_page_count * _limit,
    __from,
    __to,
    __next_cursor,
    __last_block_num,
    __last_op_id,
    __last_account_seq,
    __has_more
  )::hafbe_backend.gatherer_result;
END
$$;

RESET ROLE;

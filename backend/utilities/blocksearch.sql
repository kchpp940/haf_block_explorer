SET ROLE hafbe_owner;

-- ============================================================================
-- Block Search Utilities
-- ============================================================================
-- Functions and types for searching and filtering blocks by various criteria.
-- These support the block search API endpoints with filtering, pagination,
-- and operation-based queries.
--
-- MAIN COMPONENTS:
--   1. Block Data Functions - Retrieve block-specific data
--   2. Filter Return Types - Composite types for search results
--   3. Range Calculation Functions - Calculate valid block ranges
--   4. Pagination Functions - Handle page calculations
--   5. Block Search Functions - Find blocks matching criteria
--
-- DESIGN PATTERN:
--   Most functions return composite types to bundle related data together.
--   This reduces the number of database round-trips for API calls.
-- ============================================================================

-- ============================================================================
-- SECTION 1: Block Data Functions
-- ============================================================================
-- Functions for retrieving specific data about individual blocks.
-- ============================================================================

/*
 * get_producer_reward: Retrieves the producer reward for a specific block.
 *
 * PARAMETERS:
 *   _block_num - The block number to query
 *
 * RETURNS: The vesting shares reward amount in VESTS (as BIGINT)
 *
 * NOTE: Looks up the producer_reward_operation in the block to extract
 *       the vesting_shares amount.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_producer_reward(_block_num INT)
RETURNS BIGINT
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __op_producer_reward INT := hafbe_backend.op_producer_reward();
BEGIN
  RETURN (ov.body_value -> 'vesting_shares' ->> 'amount')::BIGINT
  FROM hive.operations_view ov
  WHERE ov.block_num = _block_num
    AND ov.op_type_id = __op_producer_reward;
END
$$;

/*
 * get_block_operation_aggregation: Retrieves operation counts per type for a block.
 *
 * PARAMETERS:
 *   _block_num - The block number to query
 *
 * RETURNS: Array of (op_type_id, op_count) tuples for all operation types in the block
 *
 * USAGE: Used by get_block endpoint to show operation breakdown.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_block_operation_aggregation(_block_num INT)
RETURNS hafbe_backend.block_operations[]
LANGUAGE 'plpgsql'
STABLE
AS
$$
BEGIN
  RETURN array_agg((op_type_id, op_count)::hafbe_backend.block_operations)
  FROM hafbe_app.block_operations
  WHERE block_num = _block_num;
END
$$;

/*
 * build_json_for_single_operation: Creates operation array for single operation response.
 *
 * PARAMETERS:
 *   _op_type_id - The operation type ID
 *   _op_count   - The operation count
 *
 * RETURNS: Single-element array of (op_type_id, op_count)
 *
 * USAGE: Helper for building consistent response format.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.build_json_for_single_operation(
    _op_type_id INT,
    _op_count   INT
)
RETURNS hafbe_backend.block_operations[]
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RETURN ARRAY[(_op_type_id, _op_count)];
END
$$;

/*
 * get_trx_count: Counts the number of transactions in a specific block.
 *
 * PARAMETERS:
 *   _block_num - The block number to query
 *
 * RETURNS: Number of transactions in the block
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_trx_count(_block_num INT)
RETURNS INT
LANGUAGE 'plpgsql'
STABLE
AS
$$
BEGIN
  RETURN COUNT(*)
  FROM hive.transactions_view
  WHERE block_num = _block_num;
END
$$;

-- ============================================================================
-- SECTION 2: Cursor Types and Functions
-- ============================================================================
-- Types and functions for cursor-based pagination to avoid deep page scans.
-- ============================================================================

/*
 * blocksearch_cursor: Decoded cursor state for pagination.
 *
 * Uses STABLE composite sort keys to avoid skipping or duplicating results
 * when multiple operations exist in the same block.
 *
 * FIELDS:
 *   block_num         - Anchor block number (where to start next page)
 *   operation_id      - Unique operation ID within block (for stable ordering)
 *   direction         - Sort direction ('asc' or 'desc')
 *   account_op_seq_no - Last seen account operation sequence (for account filters)
 *   filter_hash       - Hash of filter parameters to detect filter changes
 *   version           - Cursor format version (for future compatibility)
 *
 * SORT KEY HIERARCHY:
 *   - Account queries: account_op_seq_no (unique and stable)
 *   - Operation queries: block_num + operation_id (stable composite key)
 *
 * This ensures deterministic ordering even when:
 *   - Multiple operations exist in the same block
 *   - Multiple results map to the same account_op_seq_no
 */
DROP TYPE IF EXISTS hafbe_backend.blocksearch_cursor CASCADE;
CREATE TYPE hafbe_backend.blocksearch_cursor AS (
  block_num         INT,
  operation_id      BIGINT,
  direction         hafbe_backend.sort_direction,
  account_op_seq_no INT,
  filter_hash       TEXT,
  version           INT
);

/*
 * blocksearch_encode_cursor: Encodes cursor state into a base64 string.
 *
 * The cursor is a JSON object encoded as base64 to make it opaque and
 * URL-safe. Contains all state needed to resume pagination.
 *
 * PARAMETERS:
 *   _cursor - The decoded cursor state
 *
 * RETURNS: Base64-encoded cursor string
 *
 * FORMAT (JSON):
 *   {
 *     "v": 2,
 *     "b": <block_num>,
 *     "o": <operation_id>,
 *     "d": <direction>,
 *     "s": <account_op_seq_no>,
 *     "h": <filter_hash>
 *   }
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_encode_cursor(
  _cursor hafbe_backend.blocksearch_cursor
)
RETURNS TEXT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
DECLARE
  __json JSON;
BEGIN
  IF _cursor IS NULL THEN
    RETURN NULL;
  END IF;

  __json := json_build_object(
    'v', COALESCE(_cursor.version, 2),
    'b', _cursor.block_num,
    'o', _cursor.operation_id,
    'd', _cursor.direction,
    's', _cursor.account_op_seq_no,
    'h', _cursor.filter_hash
  );

  RETURN encode(__json::TEXT::BYTEA, 'base64');
END
$$;

/*
 * blocksearch_decode_cursor: Decodes a base64 cursor string into cursor state.
 *
 * Validates the cursor format and version. Returns NULL if cursor is NULL
 * or invalid.
 *
 * Supports backward compatibility with v1 cursors (block_num only).
 * v2 cursors include operation_id for stable ordering.
 *
 * PARAMETERS:
 *   _cursor_str - Base64-encoded cursor string
 *
 * RETURNS: Decoded blocksearch_cursor or NULL if invalid
 *
 * THROWS:
 *   Exception if cursor format is invalid or version is unsupported
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_decode_cursor(
  _cursor_str TEXT
)
RETURNS hafbe_backend.blocksearch_cursor
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
DECLARE
  __json  JSON;
  __cursor hafbe_backend.blocksearch_cursor;
  __version INT;
BEGIN
  IF _cursor_str IS NULL OR _cursor_str = '' THEN
    RETURN NULL;
  END IF;

  BEGIN
    __json := convert_from(decode(_cursor_str, 'base64'), 'UTF8')::JSON;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Invalid cursor format: must be base64-encoded JSON';
  END;

  __version := COALESCE((__json->>'v')::INT, 1);
  IF __version NOT IN (1, 2) THEN
    RAISE EXCEPTION 'Unsupported cursor version: %', __version;
  END IF;

  IF __version = 1 THEN
    __cursor := (
      (__json->>'b')::INT,
      NULL::BIGINT,
      (__json->>'d')::hafbe_backend.sort_direction,
      (__json->>'s')::INT,
      (__json->>'h')::TEXT,
      __version
    )::hafbe_backend.blocksearch_cursor;
  ELSE
    __cursor := (
      (__json->>'b')::INT,
      (__json->>'o')::BIGINT,
      (__json->>'d')::hafbe_backend.sort_direction,
      (__json->>'s')::INT,
      (__json->>'h')::TEXT,
      __version
    )::hafbe_backend.blocksearch_cursor;
  END IF;

  IF __cursor.block_num IS NULL THEN
    RAISE EXCEPTION 'Invalid cursor: missing block_num';
  END IF;

  IF __cursor.direction IS NULL THEN
    RAISE EXCEPTION 'Invalid cursor: missing direction';
  END IF;

  RETURN __cursor;
END
$$;

/*
 * blocksearch_calculate_filter_hash: Calculates a hash of filter parameters.
 *
 * Used to detect when filter parameters change between cursor requests,
 * which would invalidate the cursor.
 *
 * PARAMETERS:
 *   _operations  - Array of operation type IDs
 *   _account_id  - Account ID
 *   _key_content - Array of key-value filter values
 *   _from_block  - Start of block range
 *   _to_block    - End of block range
 *
 * RETURNS: MD5 hash string of the combined parameters
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_calculate_filter_hash(
  _operations  INT[],
  _account_id  INT,
  _key_content TEXT[],
  _from_block  INT,
  _to_block    INT
)
RETURNS TEXT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RETURN md5(
    COALESCE(array_to_string(_operations, ','), '') || '|' ||
    COALESCE(_account_id::TEXT, '') || '|' ||
    COALESCE(array_to_string(_key_content, ','), '') || '|' ||
    COALESCE(_from_block::TEXT, '') || '|' ||
    COALESCE(_to_block::TEXT, '')
  );
END
$$;

/*
 * blocksearch_validate_cursor: Validates cursor against current filter parameters.
 *
 * Checks that:
 * 1. Cursor direction matches requested direction
 * 2. Filter hash matches current filters (if provided in cursor)
 * 3. Cursor block_num is within the requested range
 *
 * PARAMETERS:
 *   _cursor        - Decoded cursor state
 *   _direction     - Requested sort direction
 *   _filter_hash   - Hash of current filter parameters
 *   _from_block    - Start of requested block range
 *   _to_block      - End of requested block range
 *
 * THROWS:
 *   Exception if any validation fails
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_validate_cursor(
  _cursor      hafbe_backend.blocksearch_cursor,
  _direction   hafbe_backend.sort_direction,
  _filter_hash TEXT,
  _from_block  INT,
  _to_block    INT
)
RETURNS VOID
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  IF _cursor IS NULL THEN
    RETURN;
  END IF;

  IF _cursor.direction != _direction THEN
    RAISE EXCEPTION 'Cursor direction (%) does not match requested direction (%). The cursor was created with direction ''%'' but the current request uses direction ''%''. Please start a new cursor-based pagination with the desired direction.',
      _cursor.direction, _direction, _cursor.direction, _direction;
  END IF;

  IF _cursor.filter_hash IS NOT NULL AND _cursor.filter_hash != _filter_hash THEN
    RAISE EXCEPTION 'Cursor is invalid: filter parameters have changed since the cursor was created. Changing operation-types, account-name, path-filter, from-block, or to-block invalidates an existing cursor. Please start a new cursor-based pagination with the updated filters.';
  END IF;

  IF _cursor.block_num < _from_block THEN
    RAISE EXCEPTION 'Cursor block_num (%) is below the requested range start (%). The cursor references a block outside the current from-block/to-block range. Please start a new cursor-based pagination with the correct range.',
      _cursor.block_num, _from_block;
  END IF;

  IF _cursor.block_num > _to_block THEN
    RAISE EXCEPTION 'Cursor block_num (%) is above the requested range end (%). The cursor references a block outside the current from-block/to-block range. Please start a new cursor-based pagination with the correct range.',
      _cursor.block_num, _to_block;
  END IF;
END
$$;

/*
 * blocksearch_validate_cursor_format: Validates that a cursor string can be decoded.
 *
 * This performs an early validation of the cursor format before any
 * database operations, providing a clear error message for malformed
 * cursors rather than letting decode failures propagate as cryptic errors.
 *
 * PARAMETERS:
 *   _cursor - The cursor string to validate (may be NULL or empty)
 *
 * RAISES: Exception if cursor is non-empty but cannot be decoded
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_validate_cursor_format(
    _cursor TEXT
)
RETURNS VOID
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  IF _cursor IS NULL OR _cursor = '' THEN
    RETURN;
  END IF;

  BEGIN
    PERFORM hafbe_backend.blocksearch_decode_cursor(_cursor);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Invalid cursor format: %. A valid cursor can be obtained from the next_cursor field of a previous response.', SQLERRM;
  END;
END
$$;

/*
 * blocksearch_get_stable_cursor_boundary: Gets stable boundary condition using composite sort key.
 *
 * Uses block_num + operation_id as a stable composite sort key to avoid
 * skipping or duplicating results when multiple operations exist in the
 * same block. The boundary condition uses row-value comparison for
 * deterministic ordering.
 *
 * For 'desc' order: (block_num, operation_id) < (cursor.block_num, cursor.operation_id)
 * For 'asc' order: (block_num, operation_id) > (cursor.block_num, cursor.operation_id)
 *
 * For v1 cursors (no operation_id), falls back to block_num-only comparison.
 *
 * PARAMETERS:
 *   _cursor          - Decoded cursor state
 *   _block_col_ref   - Block number column reference (e.g., 'bo.block_num')
 *   _op_id_col_ref   - Operation ID column reference (e.g., 'bo.id')
 *
 * RETURNS: SQL condition string fragment with stable ordering
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_get_stable_cursor_boundary(
  _cursor        hafbe_backend.blocksearch_cursor,
  _block_col_ref TEXT,
  _op_id_col_ref TEXT
)
RETURNS TEXT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  IF _cursor IS NULL THEN
    RETURN 'TRUE';
  END IF;

  IF _cursor.operation_id IS NULL THEN
    IF _cursor.direction = 'desc' THEN
      RETURN format('%s < %L', _block_col_ref, _cursor.block_num);
    ELSE
      RETURN format('%s > %L', _block_col_ref, _cursor.block_num);
    END IF;
  END IF;

  IF _cursor.direction = 'desc' THEN
    RETURN format('(%s, %s) < (%L, %L)',
      _block_col_ref, _op_id_col_ref,
      _cursor.block_num, _cursor.operation_id);
  ELSE
    RETURN format('(%s, %s) > (%L, %L)',
      _block_col_ref, _op_id_col_ref,
      _cursor.block_num, _cursor.operation_id);
  END IF;
END
$$;

/*
 * blocksearch_get_cursor_boundary: Gets the block boundary condition from cursor.
 *
 * For 'desc' order: we want blocks < cursor.block_num
 * For 'asc' order: we want blocks > cursor.block_num
 *
 * NOTE: This is the legacy block-only boundary. Use
 * blocksearch_get_stable_cursor_boundary for stable ordering.
 *
 * PARAMETERS:
 *   _cursor     - Decoded cursor state
 *   _col_ref    - Column reference for the WHERE clause (e.g., 'bo.block_num')
 *
 * RETURNS: SQL condition string fragment
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_get_cursor_boundary(
  _cursor  hafbe_backend.blocksearch_cursor,
  _col_ref TEXT
)
RETURNS TEXT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  IF _cursor IS NULL THEN
    RETURN 'TRUE';
  END IF;

  IF _cursor.direction = 'desc' THEN
    RETURN format('%s < %L', _col_ref, _cursor.block_num);
  ELSE
    RETURN format('%s > %L', _col_ref, _cursor.block_num);
  END IF;
END
$$;

/*
 * blocksearch_get_account_cursor_boundary: Gets sequence boundary for account ops.
 *
 * For 'desc' order: we want account_op_seq_no < cursor.account_op_seq_no
 * For 'asc' order: we want account_op_seq_no > cursor.account_op_seq_no
 *
 * PARAMETERS:
 *   _cursor     - Decoded cursor state
 *   _col_ref    - Column reference (e.g., 'aov.account_op_seq_no')
 *
 * RETURNS: SQL condition string fragment
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_get_account_cursor_boundary(
  _cursor  hafbe_backend.blocksearch_cursor,
  _col_ref TEXT
)
RETURNS TEXT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  IF _cursor IS NULL OR _cursor.account_op_seq_no IS NULL THEN
    RETURN 'TRUE';
  END IF;

  IF _cursor.direction = 'desc' THEN
    RETURN format('%s < %L', _col_ref, _cursor.account_op_seq_no);
  ELSE
    RETURN format('%s > %L', _col_ref, _cursor.account_op_seq_no);
  END IF;
END
$$;

-- ============================================================================
-- SECTION 3: Filter Return Types
-- ============================================================================
-- Composite types used to return bundled search results.
-- ============================================================================

/*
 * blocksearch_filter_return: Return type for block search filter functions.
 *
 * FIELDS:
 *   count_blocks - Total number of blocks matching the filter (NULL if not counted)
 *   from_block   - Starting block number of the range
 *   to_block     - Ending block number of the range
 */
DROP TYPE IF EXISTS hafbe_backend.blocksearch_filter_return CASCADE;
CREATE TYPE hafbe_backend.blocksearch_filter_return AS (
  count_blocks INT,
  from_block   INT,
  to_block     INT
);

/*
 * blocksearch_account_filter_return: Return type for account-based block searches.
 *
 * FIELDS:
 *   from_block - Starting block number of the range
 *   to_block   - Ending block number of the range
 *   from_seq   - Starting account operation sequence number
 *   to_seq     - Ending account operation sequence number
 */
DROP TYPE IF EXISTS hafbe_backend.blocksearch_account_filter_return CASCADE;
CREATE TYPE hafbe_backend.blocksearch_account_filter_return AS (
  from_block INT,
  to_block   INT,
  from_seq   INT,
  to_seq     INT
);

/*
 * calculate_pages_return: Return type for pagination calculations.
 *
 * FIELDS:
 *   rest_of_division - Remainder when dividing total by page size
 *   total_pages      - Total number of pages available
 *   page_num         - Adjusted page number for the query
 *   offset_filter    - SQL OFFSET value for the query
 *   limit_filter     - SQL LIMIT value for the query
 */
DROP TYPE IF EXISTS hafbe_backend.calculate_pages_return CASCADE;
CREATE TYPE hafbe_backend.calculate_pages_return AS (
  rest_of_division INT,
  total_pages      INT,
  page_num         INT,
  offset_filter    INT,
  limit_filter     INT
);

/*
 * find_blocks_with_op_return: Return type for operation-based block searches.
 *
 * FIELDS:
 *   block_num  - Block number where the operation was found
 *   op_type_id - Operation type ID
 *   op_count   - Number of operations of this type in the block (NULL for account searches)
 */
DROP TYPE IF EXISTS hafbe_backend.find_blocks_with_op_return CASCADE;
CREATE TYPE hafbe_backend.find_blocks_with_op_return AS (
  block_num  INT,
  op_type_id INT,
  op_count   INT
);

/*
 * gathered_block: Intermediate block representation for gatherer functions.
 *
 * FIELDS:
 *   block_num  - Block number
 *   operations - Array of operation counts for this block
 *
 * USAGE: Used by gatherer functions to pass block data to the finalize step
 *        before enrichment with metadata (hash, prev, producer_account, etc.)
 */
DROP TYPE IF EXISTS hafbe_backend.gathered_block CASCADE;
CREATE TYPE hafbe_backend.gathered_block AS (
  block_num  INT,
  operations hafbe_backend.block_operations[]
);

/*
 * gatherer_result: Return type for all block search gatherer functions.
 *
 * FIELDS:
 *   blocks            - Array of (block_num, operations) tuples, paginated and ordered
 *   total_count       - Total number of blocks matching the filter (may be capped)
 *   total_pages       - Total number of pages available (for page-based pagination)
 *   min_block_num     - Minimum block number found (for legacy cursor calculation)
 *   pre_grouped_count - Count of operations before grouping (for saturation check)
 *   max_page_limit    - __max_page_count * _limit (for saturation check)
 *   range_from        - Normalized start of block range
 *   range_to          - Normalized end of block range
 *   next_cursor       - Encoded cursor string for next page (NULL if no more results)
 *   last_block_num    - Last block number in results (for cursor encoding)
 *   last_operation_id - Last operation ID in results (for stable cursor ordering)
 *   last_account_seq  - Last account operation sequence (for account filter cursors)
 *   has_more          - Whether there are more results after this page
 *
 * CURSOR LOGIC:
 *   The next_cursor is calculated by each gatherer using:
 *   - last_block_num: the last block in the result set (direction-aware)
 *   - last_operation_id: the last operation ID for stable ordering
 *   - last_account_seq: for account-based queries, last account_op_seq_no
 *   - has_more: whether LIMIT+1 rows were found (indicating more data)
 */
DROP TYPE IF EXISTS hafbe_backend.gatherer_result CASCADE;
CREATE TYPE hafbe_backend.gatherer_result AS (
  blocks            hafbe_backend.gathered_block[],
  total_count       INT,
  total_pages       INT,
  min_block_num     INT,
  pre_grouped_count INT,
  max_page_limit    INT,
  range_from        INT,
  range_to          INT,
  next_cursor       TEXT,
  last_block_num    INT,
  last_operation_id BIGINT,
  last_account_seq  INT,
  has_more          BOOLEAN
);

-- ============================================================================
-- SECTION 4: Range Calculation Functions
-- ============================================================================
-- Functions that calculate and normalize block ranges for queries.
-- Handle NULL inputs by using defaults (genesis or current head).
-- ============================================================================

/*
 * blocksearch_no_filter_count: Calculates block count without any operation filter.
 *
 * Simply counts blocks in the range. Used when no operation type filter is applied.
 *
 * PARAMETERS:
 *   _from          - Starting block (NULL = genesis block)
 *   _to            - Ending block (NULL = current head)
 *   _current_block - Current head block number
 *
 * RETURNS: blocksearch_filter_return with count and normalized range
 *
 * FORMULA: count = to - from + 1
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_no_filter_count(
    _from          INT,
    _to            INT,
    _current_block INT
)
RETURNS hafbe_backend.blocksearch_filter_return
LANGUAGE 'plpgsql'
IMMUTABLE
SET JIT = OFF
AS
$$
DECLARE
  __genesis_block INT := hafbe_backend.genesis_block_num();
  __to            INT;
  __from          INT;
  __count         INT;
BEGIN
  -- Normalize _to: use current_block if NULL or if requested block exceeds current
  __to := CASE
    WHEN _to IS NULL THEN _current_block
    WHEN _current_block < _to THEN _current_block
    ELSE _to
  END;

  -- Normalize _from: use genesis if NULL
  __from := CASE
    WHEN _from IS NULL THEN __genesis_block
    ELSE _from
  END;

  __count := __to - __from + 1;

  RETURN (__count, __from, __to)::hafbe_backend.blocksearch_filter_return;
END
$$;

/*
 * blocksearch_range: Calculates normalized block range without counting.
 *
 * Returns NULL for count - used when count will be determined separately
 * (e.g., by operation filter).
 *
 * PARAMETERS:
 *   _from          - Starting block (NULL = genesis block)
 *   _to            - Ending block (NULL = current head)
 *   _current_block - Current head block number
 *
 * RETURNS: blocksearch_filter_return with NULL count and normalized range
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_range(
    _from          INT,
    _to            INT,
    _current_block INT
)
RETURNS hafbe_backend.blocksearch_filter_return
LANGUAGE 'plpgsql'
IMMUTABLE
SET JIT = OFF
AS
$$
DECLARE
  __genesis_block INT := hafbe_backend.genesis_block_num();
  __to            INT;
  __from          INT;
BEGIN
  -- Normalize _to: use current_block if NULL or if requested block exceeds current
  __to := CASE
    WHEN _to IS NULL THEN _current_block
    WHEN _current_block < _to THEN _current_block
    ELSE _to
  END;

  -- Normalize _from: use genesis if NULL
  __from := CASE
    WHEN _from IS NULL THEN __genesis_block
    ELSE _from
  END;

  RETURN (NULL, __from, __to)::hafbe_backend.blocksearch_filter_return;
END
$$;

/*
 * blocksearch_account_range: Calculates block and sequence range for account-based search.
 *
 * In addition to block range, calculates the account operation sequence numbers
 * for the first and last operations within the range.
 *
 * PARAMETERS:
 *   _account_id    - Account ID to search for
 *   _from          - Starting block (NULL = genesis block)
 *   _to            - Ending block (NULL = current head)
 *   _current_block - Current head block number
 *
 * RETURNS: blocksearch_account_filter_return with block range and sequence range
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_account_range(
    _account_id    INT,
    _from          INT,
    _to            INT,
    _current_block INT
)
RETURNS hafbe_backend.blocksearch_account_filter_return
LANGUAGE 'plpgsql'
STABLE
SET JIT = OFF
AS
$$
DECLARE
  __genesis_block INT := hafbe_backend.genesis_block_num();
  __to            INT;
  __from          INT;
  __to_seq        INT;
  __from_seq      INT;
BEGIN
  -- Normalize _to: use current_block if NULL or if requested block exceeds current
  __to := CASE
    WHEN _to IS NULL THEN _current_block
    WHEN _current_block < _to THEN _current_block
    ELSE _to
  END;

  -- Normalize _from: use genesis if NULL
  __from := CASE
    WHEN _from IS NULL THEN __genesis_block
    ELSE _from
  END;

  -- Find the last operation sequence number at or before __to
  __to_seq := (
    SELECT aov.account_op_seq_no
    FROM hive.account_operations_view aov
    WHERE aov.account_id = _account_id
      AND aov.block_num <= __to
    ORDER BY aov.account_op_seq_no DESC
    LIMIT 1
  );

  -- Find the first operation sequence number at or after __from
  __from_seq := (
    SELECT aov.account_op_seq_no
    FROM hive.account_operations_view aov
    WHERE aov.account_id = _account_id
      AND aov.block_num >= __from
    ORDER BY aov.account_op_seq_no ASC
    LIMIT 1
  );

  RETURN (__from, __to, __from_seq, __to_seq)::hafbe_backend.blocksearch_account_filter_return;
END
$$;

/*
 * blocksearch_by_op_count: Counts blocks containing a specific operation type.
 *
 * Used when filtering by operation type to determine pagination.
 * Limited to max_page_count * limit blocks to prevent unbounded queries.
 *
 * PARAMETERS:
 *   _operation     - Operation type ID to filter by
 *   _from          - Starting block (NULL = genesis block)
 *   _to            - Ending block (NULL = current head)
 *   _current_block - Current head block number
 *   _order_is      - Sort direction ('asc' or 'desc')
 *   _limit         - Page size
 *
 * RETURNS: blocksearch_filter_return with count (limited) and normalized range
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_by_op_count(
    _operation     INT,
    _from          INT,
    _to            INT,
    _current_block INT,
    _order_is      hafbe_backend.sort_direction,
    _limit         INT
)
RETURNS hafbe_backend.blocksearch_filter_return
LANGUAGE 'plpgsql'
STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __genesis_block  INT := hafbe_backend.genesis_block_num();
  __max_page_count INT := hafbe_backend.default_max_page_count();
  __to             INT;
  __from           INT;
BEGIN
  -- Normalize _to: use current_block if NULL or if requested block exceeds current
  __to := CASE
    WHEN _to IS NULL THEN _current_block
    WHEN _current_block < _to THEN _current_block
    ELSE _to
  END;

  -- Normalize _from: use genesis if NULL
  __from := CASE
    WHEN _from IS NULL THEN __genesis_block
    ELSE _from
  END;

  RETURN (
    WITH blocks AS (
      SELECT COUNT(*) AS count_blocks
      FROM (
        SELECT *
        FROM hafbe_app.block_operations ov
        WHERE ov.op_type_id = _operation
          AND ov.block_num <= __to
          AND ov.block_num >= __from
        ORDER BY
          (CASE WHEN _order_is = 'desc' THEN ov.block_num ELSE NULL END) DESC,
          (CASE WHEN _order_is = 'asc' THEN ov.block_num ELSE NULL END) ASC
        -- Limit to max_page_count pages to prevent unbounded queries
        LIMIT (__max_page_count * _limit)
      )
    )
    SELECT (count_blocks, __from, __to)::hafbe_backend.blocksearch_filter_return
    FROM blocks
  );
END
$$;

-- ============================================================================
-- SECTION 5: Pagination Functions
-- ============================================================================
-- Functions for calculating pagination parameters.
-- ============================================================================

/*
 * blocksearch_calculate_pages: Calculates pagination parameters for block search.
 *
 * Handles the complexity of pagination with both ascending and descending order,
 * including partial pages at the boundaries.
 *
 * PARAMETERS:
 *   _count    - Total number of items
 *   _page     - Requested page number (1-based)
 *   _order_is - Sort direction ('asc' or 'desc')
 *   _limit    - Page size
 *
 * RETURNS: calculate_pages_return with all pagination parameters
 *
 * PAGINATION LOGIC:
 *   For 'desc' order, page 1 is the LAST page (most recent blocks).
 *   For 'asc' order, page 1 is the FIRST page (oldest blocks).
 *
 *   When total count is not evenly divisible by page size:
 *   - For 'desc': page 1 gets the smaller "remainder" page
 *   - For 'asc': last page gets the smaller "remainder" page
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_calculate_pages(
    _count    INT,
    _page     INT,
    _order_is hafbe_backend.sort_direction,
    _limit    INT
)
RETURNS hafbe_backend.calculate_pages_return
LANGUAGE 'plpgsql'
STABLE
SET JIT = OFF
AS
$$
DECLARE
  __rest_of_division INT;
  __total_pages      INT;
  __page             INT;
  __offset           INT;
  __limit            INT;
BEGIN
  -- Handle zero count case early
  IF _count = 0 OR _count IS NULL THEN
    RETURN (0, 0, 0, 0, _limit)::hafbe_backend.calculate_pages_return;
  END IF;

  __rest_of_division := (_count % _limit)::INT;

  __total_pages := CASE
    WHEN __rest_of_division = 0 THEN _count / _limit
    ELSE (_count / _limit) + 1
  END::INT;

  -- Adjust page number for descending order (page 1 = most recent)
  __page := CASE
    WHEN _page IS NULL THEN 1
    WHEN _page IS NOT NULL AND _order_is = 'desc' THEN __total_pages - _page + 1
    ELSE _page
  END;

  -- Calculate offset accounting for partial pages
  __offset := CASE
    WHEN _order_is = 'desc' AND __page != 1 AND __rest_of_division != 0 THEN
      ((__page - 2) * _limit) + __rest_of_division
    WHEN __page = 1 THEN 0
    ELSE (__page - 1) * _limit
  END;

  -- Calculate limit accounting for partial pages
  __limit := CASE
    WHEN _order_is = 'desc' AND __page = 1 AND __rest_of_division != 0 THEN
      __rest_of_division
    WHEN _order_is = 'asc' AND __page = __total_pages AND __rest_of_division != 0 THEN
      __rest_of_division
    ELSE _limit
  END;

  PERFORM hafah_backend.validate_page(_page, __total_pages);

  RETURN (__rest_of_division, __total_pages, __page, __offset, __limit)::hafbe_backend.calculate_pages_return;
END
$$;

-- ============================================================================
-- SECTION 6: Block Search Functions
-- ============================================================================
-- Functions for finding blocks matching specific criteria.
-- ============================================================================

/*
 * find_blocks_with_op: Finds blocks containing a specific operation type.
 *
 * Returns blocks in the specified range that contain at least one operation
 * of the given type, along with the count of operations in each block.
 *
 * PARAMETERS:
 *   _operation - Operation type ID to search for
 *   _from      - Starting block number
 *   _to        - Ending block number
 *   _order_is  - Sort direction ('asc' or 'desc')
 *   _limit     - Maximum number of results
 *
 * RETURNS: Set of (block_num, op_type_id, op_count) rows
 */
CREATE OR REPLACE FUNCTION hafbe_backend.find_blocks_with_op(
    _operation INT,
    _from      INT,
    _to        INT,
    _order_is  hafbe_backend.sort_direction,
    _limit     INT
)
RETURNS SETOF hafbe_backend.find_blocks_with_op_return
LANGUAGE 'plpgsql'
STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
BEGIN
  RETURN QUERY (
    SELECT
      bo.block_num,
      bo.op_type_id,
      bo.op_count
    FROM hafbe_app.block_operations bo
    WHERE bo.op_type_id = _operation
      AND bo.block_num >= _from
      AND bo.block_num <= _to
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN bo.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN bo.block_num ELSE NULL END) ASC
    LIMIT _limit
  );
END
$$;

/*
 * find_blocks_with_op_and_account: Finds blocks where an account has a specific operation.
 *
 * Searches the account_operations_view to find blocks where the specified
 * account participated in the given operation type.
 *
 * PARAMETERS:
 *   _operation  - Operation type ID to search for
 *   _account_id - Account ID to filter by
 *   _from       - Starting block number
 *   _to         - Ending block number
 *   _order_is   - Sort direction ('asc' or 'desc')
 *   _limit      - Maximum number of results
 *
 * RETURNS: Set of (block_num, op_type_id, NULL) rows
 *          Note: op_count is NULL since we're searching by account, not aggregating
 */
CREATE OR REPLACE FUNCTION hafbe_backend.find_blocks_with_op_and_account(
    _operation  INT,
    _account_id INT,
    _from       INT,
    _to         INT,
    _order_is   hafbe_backend.sort_direction,
    _limit      INT
)
RETURNS SETOF hafbe_backend.find_blocks_with_op_return
LANGUAGE 'plpgsql'
STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
BEGIN
  RETURN QUERY (
    SELECT
      aov.block_num,
      aov.op_type_id,
      NULL::INT
    FROM hive.account_operations_view aov
    WHERE aov.op_type_id = _operation
      AND aov.account_id = _account_id
      AND aov.block_num >= _from
      AND aov.block_num <= _to
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN aov.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN aov.block_num ELSE NULL END) ASC
    LIMIT _limit
  );
END
$$;

-- ============================================================================
-- SECTION 7: Result Building Functions
-- ============================================================================
-- Functions for building final API responses from gatherer results.
-- ============================================================================

/*
 * blocksearch_build_result: Enriches gathered blocks and builds the final API response.
 *
 * This is the SINGLE point of enrichment for all block search filters.
 * It takes the intermediate gatherer_result and:
 *   1. Enriches each block with metadata from blocks_view
 *   2. Adds producer_reward, trx_count via helper functions
 *   3. Returns the final block_history response
 *
 * PARAMETERS:
 *   _gathered - The gatherer_result from any filter function
 *   _order_is - Sort direction ('asc' or 'desc')
 *
 * RETURNS: block_history with enriched block data
 *
 * NOTES:
 *   - next_cursor is pre-computed by each gatherer and stored in _gathered.next_cursor
 *   - block_range.from is the cursor for next page (legacy from-block adjustment)
 *   - For cursor pagination, use the next_cursor field in the API response
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_build_result(
    _gathered hafbe_backend.gatherer_result,
    _order_is hafbe_backend.sort_direction
)
RETURNS hafbe_backend.block_history
LANGUAGE 'plpgsql'
STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET JIT = OFF
AS
$$
DECLARE
  __cursor_from INT;
  __result      hafbe_backend.blocksearch[];
BEGIN
  -- Handle empty result case
  IF _gathered.total_pages = 0 OR _gathered.blocks IS NULL OR array_length(_gathered.blocks, 1) IS NULL THEN
    RETURN (
      COALESCE(_gathered.total_count, 0),
      COALESCE(_gathered.total_pages, 0),
      (_gathered.range_from, _gathered.range_to)::hafbe_backend.block_range,
      '{}'::hafbe_backend.blocksearch[],
      _gathered.next_cursor,
      _gathered.has_more
    )::hafbe_backend.block_history;
  END IF;

  -- Calculate legacy cursor (from_block adjustment) for backward compatibility
  __cursor_from := CASE
    WHEN _gathered.min_block_num IS NULL THEN
      _gathered.range_from
    WHEN _gathered.min_block_num = 1 THEN
      1
    WHEN _gathered.pre_grouped_count != _gathered.max_page_limit THEN
      _gathered.range_from
    ELSE
      _gathered.min_block_num - 1
  END;

  -- Enrich blocks with metadata and build result array
  SELECT array_agg(row ORDER BY
    (CASE WHEN _order_is = 'desc' THEN row.block_num ELSE NULL END) DESC,
    (CASE WHEN _order_is = 'asc' THEN row.block_num ELSE NULL END) ASC
  )
  INTO __result
  FROM (
    SELECT
      g.block_num,
      bv.created_at,
      hafah_backend.get_account_name(bv.producer_account_id) AS producer_account,
      hafbe_backend.get_producer_reward(g.block_num)::TEXT AS producer_reward,
      hafbe_backend.get_trx_count(g.block_num) AS trx_count,
      encode(bv.hash, 'hex') AS hash,
      encode(bv.prev, 'hex') AS prev,
      g.operations
    FROM unnest(_gathered.blocks) AS g(block_num, operations)
    JOIN hive.blocks_view bv ON bv.num = g.block_num
  ) row;

  RETURN (
    COALESCE(_gathered.total_count, 0),
    COALESCE(_gathered.total_pages, 0),
    (__cursor_from, _gathered.range_to)::hafbe_backend.block_range,
    COALESCE(__result, '{}'::hafbe_backend.blocksearch[]),
    _gathered.next_cursor,
    _gathered.has_more
  )::hafbe_backend.block_history;
END
$$;

RESET ROLE;

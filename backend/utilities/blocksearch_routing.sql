SET ROLE hafbe_owner;

-- ============================================================================
-- Block Search Routing Plan
-- ============================================================================
-- Complete routing and boundary logic for block search API. This module
-- extracts ALL routing decisions, parameter validation, pagination, cursor
-- handling, and gatherer dispatch from get_blocks_by_ops and the individual
-- gatherer functions.
--
-- MAIN COMPONENTS:
--   1. Route Type Enum         - Names for each possible gatherer route
--   2. Routing Context Type    - Complete execution context (params + state)
--   3. Route Determination     - Analyze inputs to select the route
--   4. Parameter Validation    - All validation logic centralized here
--   5. Max Page Count Calc     - Unified max_page_count for all routes
--   6. Gatherer Invocation     - Single dispatch with normalized parameters
--   7. Result Building         - Cursor calculation + response enrichment
--
-- DESIGN PHILOSOPHY:
--   - Single source of truth for ALL block search logic
--   - Declarative: "what" to do, not "how" to compute it
--   - Zero conditional logic in callers (get_block_by_op, get_blocks_by_ops)
--   - All gatherers invoked through a normalized interface
-- ============================================================================

-- ============================================================================
-- SECTION 1: Route Type and Routing Context
-- ============================================================================
-- Complete context for a block search request - all decisions, all params.
-- ============================================================================

/*
 * blocksearch_route: Enum of all possible block search gatherer routes.
 *
 * Each value corresponds to one of the 8 filter combinations:
 *   no_filter           - No filters
 *   single_op           - Single operation type
 *   multi_op            - Multiple operation types
 *   key_value           - Single op + key-value filter
 *   account             - Account only
 *   account_op          - Account + single operation
 *   account_multi_op    - Account + multiple operations
 *   account_key_value   - Account + single op + key-value
 */
DROP TYPE IF EXISTS hafbe_backend.blocksearch_route CASCADE;
CREATE TYPE hafbe_backend.blocksearch_route AS ENUM (
  'no_filter',
  'single_op',
  'multi_op',
  'key_value',
  'account',
  'account_op',
  'account_multi_op',
  'account_key_value'
);

/*
 * blocksearch_context: Complete execution context for block search.
 *
 * This single type carries ALL information needed for the entire pipeline:
 * raw parameters, routing decisions, pagination state, cursor info.
 *
 * FIELDS - Route Decisions:
 *   route               - Which gatherer to use
 *   has_op_filter       - Whether operation filter is applied
 *   is_single_op        - Whether exactly one operation type
 *   has_account_filter  - Whether account filter is applied
 *   has_key_filter      - Whether key-value filter is applied
 *   single_op_id        - Operation ID when is_single_op = true
 *   max_page_count      - Max pages to fetch (route-specific)
 *
 * FIELDS - Raw Parameters:
 *   operations          - Array of operation type IDs
 *   account_id          - Account ID
 *   from_block          - Starting block number
 *   to_block            - Ending block number
 *   order_is            - Sort direction
 *   page                - Page number (1-based)
 *   page_size           - Page size (limit)
 *   key_content         - Values for key-value filter
 *   setof_keys          - JSON paths for key-value filter
 *
 * FIELDS - State / Derived Values:
 *   current_block       - Current head block number (passed to gatherers)
 *   is_irreversible     - Whether the range is fully irreversible (for caching)
 */
DROP TYPE IF EXISTS hafbe_backend.blocksearch_context CASCADE;
CREATE TYPE hafbe_backend.blocksearch_context AS (
  -- Route decisions
  route               hafbe_backend.blocksearch_route,
  has_op_filter       BOOLEAN,
  is_single_op        BOOLEAN,
  has_account_filter  BOOLEAN,
  has_key_filter      BOOLEAN,
  single_op_id        INT,
  max_page_count      INT,

  -- Raw parameters
  operations          INT[],
  account_id          INT,
  from_block          INT,
  to_block            INT,
  order_is            hafbe_backend.sort_direction,
  page                INT,
  page_size           INT,
  key_content         TEXT[],
  setof_keys          JSON,

  -- State / derived
  current_block       INT,
  is_irreversible     BOOLEAN
);

-- ============================================================================
-- SECTION 2: Route Determination
-- ============================================================================
-- Analyze input parameters to determine which route to take.
-- ============================================================================

/*
 * blocksearch_determine_route: Determines which gatherer route to use.
 *
 * Single source of truth for routing decisions. Uses a nested decision tree
 * for readability - each level answers a binary question.
 *
 * DECISION TREE (ASCII):
 *
 *   has_account?
 *   ├─ NO:
 *   │  has_op?
 *   │  ├─ NO  → no_filter
 *   │  └─ YES:
 *   │      is_single_op?
 *   │      ├─ YES:
 *   │      │  has_key? → key_value : single_op
 *   │      └─ NO  → multi_op
 *   └─ YES:
 *      has_op?
 *      ├─ NO  → account
 *      └─ YES:
 *          is_single_op?
 *          ├─ YES:
 *          │  has_key? → account_key_value : account_op
 *          └─ NO  → account_multi_op
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_determine_route(
    _operations  INT[],
    _account_id  INT,
    _key_content TEXT[]
)
RETURNS hafbe_backend.blocksearch_route
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
DECLARE
  __has_op      BOOLEAN := (_operations IS NOT NULL);
  __is_single   BOOLEAN := (_operations IS NOT NULL AND array_length(_operations, 1) = 1);
  __has_account BOOLEAN := (_account_id IS NOT NULL);
  __has_key     BOOLEAN := (_key_content[1] IS NOT NULL);
BEGIN
  RETURN CASE
    WHEN NOT __has_account THEN
      CASE
        WHEN NOT __has_op THEN
          'no_filter'::hafbe_backend.blocksearch_route
        ELSE
          CASE
            WHEN __is_single THEN
              CASE
                WHEN __has_key THEN
                  'key_value'::hafbe_backend.blocksearch_route
                ELSE
                  'single_op'::hafbe_backend.blocksearch_route
              END
            ELSE
              'multi_op'::hafbe_backend.blocksearch_route
          END
      END
    ELSE
      CASE
        WHEN NOT __has_op THEN
          'account'::hafbe_backend.blocksearch_route
        ELSE
          CASE
            WHEN __is_single THEN
              CASE
                WHEN __has_key THEN
                  'account_key_value'::hafbe_backend.blocksearch_route
                ELSE
                  'account_op'::hafbe_backend.blocksearch_route
              END
            ELSE
              'account_multi_op'::hafbe_backend.blocksearch_route
          END
      END
  END;
END
$$;

/*
 * blocksearch_get_max_page_count: Returns max_page_count for a given route.
 *
 * SINGLE SOURCE OF TRUTH - all gatherers use values from this function:
 *   no_filter           → N/A (not used)
 *   single_op           → 10
 *   multi_op            → N = number of operation types
 *   key_value           → 10
 *   account             → 10
 *   account_op          → 10
 *   account_multi_op    → N = number of operation types
 *   account_key_value   → 10
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_get_max_page_count(
    _route      hafbe_backend.blocksearch_route,
    _operations INT[]
)
RETURNS INT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RETURN CASE _route
    WHEN 'no_filter'::hafbe_backend.blocksearch_route            THEN 1
    WHEN 'single_op'::hafbe_backend.blocksearch_route            THEN 10
    WHEN 'multi_op'::hafbe_backend.blocksearch_route             THEN array_length(_operations, 1)
    WHEN 'key_value'::hafbe_backend.blocksearch_route            THEN 10
    WHEN 'account'::hafbe_backend.blocksearch_route              THEN 10
    WHEN 'account_op'::hafbe_backend.blocksearch_route           THEN 10
    WHEN 'account_multi_op'::hafbe_backend.blocksearch_route     THEN array_length(_operations, 1)
    WHEN 'account_key_value'::hafbe_backend.blocksearch_route    THEN 10
    ELSE 10
  END;
END
$$;

/*
 * blocksearch_create_context: Creates the complete routing context.
 *
 * This is the ENTRY POINT for the entire routing system. Callers only
 * need to call this function - all decisions are made here.
 *
 * PARAMETERS:
 *   All raw parameters from the API endpoint
 *
 * RETURNS:
 *   Fully populated blocksearch_context with ALL decisions made
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_create_context(
    _operations  INT[],
    _account_id  INT,
    _from_block  INT,
    _to_block    INT,
    _order_is    hafbe_backend.sort_direction,
    _page        INT,
    _page_size   INT,
    _key_content TEXT[],
    _setof_keys  JSON
)
RETURNS hafbe_backend.blocksearch_context
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __route           hafbe_backend.blocksearch_route;
  __has_op          BOOLEAN := (_operations IS NOT NULL);
  __is_single       BOOLEAN := (_operations IS NOT NULL AND array_length(_operations, 1) = 1);
  __has_account     BOOLEAN := (_account_id IS NOT NULL);
  __has_key         BOOLEAN := (_key_content[1] IS NOT NULL);
  __single_op_id    INT     := CASE WHEN __is_single THEN _operations[1] ELSE NULL END;
  __max_page_count  INT;
  __current_block   INT;
  __is_irreversible BOOLEAN;
BEGIN
  -- Route decision
  __route := hafbe_backend.blocksearch_determine_route(_operations, _account_id, _key_content);

  -- Max page count (unified across all routes)
  __max_page_count := hafbe_backend.blocksearch_get_max_page_count(__route, _operations);

  -- Current block (SINGLE QUERY - passed to all gatherers instead of each querying)
  __current_block := hafbe_backend.get_hafbe_head_block();

  -- Irreversibility check (for cache headers)
  __is_irreversible := CASE
    WHEN _to_block IS NOT NULL AND _to_block <= hive.app_get_irreversible_block() THEN TRUE
    ELSE FALSE
  END;

  RETURN (
    -- Route decisions
    __route,
    __has_op,
    __is_single,
    __has_account,
    __has_key,
    __single_op_id,
    __max_page_count,

    -- Raw parameters
    _operations,
    _account_id,
    _from_block,
    _to_block,
    _order_is,
    _page,
    _page_size,
    _key_content,
    _setof_keys,

    -- State / derived
    __current_block,
    __is_irreversible
  )::hafbe_backend.blocksearch_context;
END
$$;

-- ============================================================================
-- SECTION 3: Parameter Validation
-- ============================================================================
-- ALL validation logic centralized here.
-- ============================================================================

/*
 * blocksearch_validate: Performs ALL validation for a block search request.
 *
 * SINGLE POINT OF VALIDATION - includes:
 *   1. Page size validation (max 1000, positive)
 *   2. Page number validation (positive)
 *   3. Block range validation (not exceeding head block)
 *   4. Key filter prerequisites (indexes installed, single operation)
 *   5. Key filter path validation (valid keys for operation type)
 *
 * PARAMETERS:
 *   _ctx           - The routing context
 *   _head_block    - Current head block number
 *
 * THROWS:
 *   Appropriate exception if any validation fails
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_validate(
    _ctx        hafbe_backend.blocksearch_context,
    _head_block INT
)
RETURNS VOID
LANGUAGE 'plpgsql'
STABLE
AS
$$
BEGIN
  -- 1. Pagination validation
  PERFORM hafbe_backend.validate_limit(_ctx.page_size, 1000);
  PERFORM hafbe_backend.validate_negative_limit(_ctx.page_size);
  PERFORM hafbe_backend.validate_negative_page(_ctx.page);

  -- 2. Block range validation
  PERFORM hafbe_backend.validate_block_num_too_high(_ctx.from_block, _head_block);

  -- 3. Key filter validation (if key filter applied)
  IF _ctx.has_key_filter THEN
    -- Validate indexes are installed
    PERFORM hafbe_backend.validate_block_search_indexes();
    -- Validate single operation (required for key filter)
    PERFORM hafbe_backend.validate_single_operation_type(_ctx.operations);
    -- Validate key paths are valid for the operation
    PERFORM hafbe_backend.validate_path_filter_keys(_ctx.operations, _ctx.setof_keys);
  END IF;

  -- 4. Route sanity check
  IF _ctx.route IS NULL THEN
    RAISE EXCEPTION 'Invalid parameter combination: could not determine route';
  END IF;
END
$$;

-- ============================================================================
-- SECTION 4: Candidate + Pagination Types
-- ============================================================================
-- Intermediate types for separating "what to gather" from "how to paginate".
-- ============================================================================

/*
 * blocksearch_candidates: Intermediate result from gatherers before pagination.
 *
 * Each gatherer only produces this - all pagination logic is centralized.
 *
 * FIELDS:
 *   candidate_blocks  - Deduplicated, stably-sorted blocks (all matches, unpaginated)
 *   pre_grouped_count - Count of operations before deduplication (for saturation check)
 *   range_from        - Normalized start of block range
 *   range_to          - Normalized end of block range
 *
 * PURPOSE: Separation of concerns:
 *   - Gatherer: "find all matching blocks, sort them, deduplicate, normalize range"
 *   - Pagination helper: "slice into pages, calculate saturation, build result"
 */
DROP TYPE IF EXISTS hafbe_backend.blocksearch_candidates CASCADE;
CREATE TYPE hafbe_backend.blocksearch_candidates AS (
  candidate_blocks  hafbe_backend.gathered_block[],
  pre_grouped_count INT,
  range_from        INT,
  range_to          INT
);

-- ============================================================================
-- SECTION 5: Gatherer Invocation
-- ============================================================================
-- Single dispatch point with normalized parameters.
--
-- NOTE: This handles the parameter order inconsistency across gatherers:
--   - account_op:      (_operation, _account_id, ...)
--   - account_multi_op:(_operations, _account_id, ...)
--   - account_key_value:(_operation, _account_id, ...)
-- ============================================================================

/*
 * blocksearch_invoke_gatherer: Invokes the appropriate gatherer for the route.
 *
 * SINGLE DISPATCH POINT - ALL 8 gatherers called from here.
 *
 * UNIFIED PIPELINE (same for ALL routes):
 *   1. Call gatherer to get blocksearch_candidates (sorted, deduplicated blocks)
 *      - ALL gatherers return blocksearch_candidates
 *      - NO gatherer handles pagination internally
 *      - NO special cases for any route
 *   2. Call blocksearch_paginate_window to apply pagination (OFFSET + LIMIT)
 *   3. Return final gatherer_result
 *
 * This handles parameter order normalization internally:
 *   - account_op:      (_operation, _account_id, ...)
 *   - account_multi_op:(_operations, _account_id, ...)
 *   - account_key_value:(_operation, _account_id, ...)
 *
 * PARAMETERS:
 *   _ctx - Complete routing context
 *
 * RETURNS:
 *   gatherer_result with pagination applied
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_invoke_gatherer(
    _ctx hafbe_backend.blocksearch_context
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __candidates hafbe_backend.blocksearch_candidates;
  __needs_min  BOOLEAN;
BEGIN
  -- Determine if we need min_block_num (filtered searches = true, no_filter = false)
  -- For no_filter: cursor always returns range_from (no adjustment needed)
  -- For filtered: min_block_num is used for saturation-based cursor adjustment
  __needs_min := (_ctx.route != 'no_filter'::hafbe_backend.blocksearch_route);

  -- Step 1: Invoke gatherer to get candidates (sorted, deduplicated blocks)
  -- ALL 8 gatherers return blocksearch_candidates (composite type), no pagination inside
  __candidates := CASE _ctx.route
    -- No filters
    WHEN 'no_filter'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_no_filter(
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Single operation
    WHEN 'single_op'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_single_op(
        _ctx.single_op_id,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Multiple operations
    WHEN 'multi_op'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_multi_op(
        _ctx.operations,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Single operation + key-value
    WHEN 'key_value'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_key_value(
        _ctx.single_op_id,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.key_content,
        _ctx.setof_keys,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Account only
    WHEN 'account'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_account(
        _ctx.account_id,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Account + single operation
    WHEN 'account_op'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_account_op(
        _ctx.single_op_id,
        _ctx.account_id,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Account + multiple operations
    WHEN 'account_multi_op'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_account_multi_op(
        _ctx.operations,
        _ctx.account_id,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.current_block,
        _ctx.max_page_count
      )

    -- Account + single operation + key-value
    WHEN 'account_key_value'::hafbe_backend.blocksearch_route THEN
      hafbe_backend.blocksearch_account_key_value(
        _ctx.single_op_id,
        _ctx.account_id,
        _ctx.from_block,
        _ctx.to_block,
        _ctx.order_is,
        _ctx.page_size,
        _ctx.key_content,
        _ctx.setof_keys,
        _ctx.current_block,
        _ctx.max_page_count
      )

    ELSE
      RAISE EXCEPTION 'Unknown route: %', _ctx.route
  END;

  -- Step 2: Apply unified pagination window (ALL routes go through here)
  -- For no_filter: _needs_min = false, so min_block_num = NULL, cursor stays at range_from
  -- For filtered: _needs_min = true, saturation-based cursor adjustment
  RETURN hafbe_backend.blocksearch_paginate_window(
    __candidates,
    __candidates.range_from,
    __candidates.range_to,
    _ctx.order_is,
    _ctx.page,
    _ctx.page_size,
    _ctx.max_page_count,
    __needs_min
  );
END
$$;

-- ============================================================================
-- SECTION 6: Pagination Window Helper
-- ============================================================================
-- Unified pagination logic for ALL gatherers.
--
-- INPUT:  blocksearch_candidates (deduplicated, sorted blocks + pre_grouped_count)
-- OUTPUT: gatherer_result (paginated + cursor-aware + saturation-checked)
--
-- RESPONSIBILITIES (single source of truth for ALL of these):
--   1. Extract min_block_num (last key for cursor)
--   2. Calculate total_count (array length of candidates)
--   3. Calculate pages via blocksearch_calculate_pages
--   4. Apply OFFSET + LIMIT for pagination
--   5. Handle empty result case
--   6. Build final gatherer_result with saturation markers
-- ============================================================================

/*
 * blocksearch_paginate_window: Applies unified pagination to gatherer candidates.
 *
 * This is the SINGLE source of truth for pagination logic across ALL 8 gatherers.
 * Each gatherer only needs to produce deduplicated, sorted candidates - this
 * function handles everything else.
 *
 * PARAMETERS:
 *   _candidates    - Output from a gatherer: sorted blocks + pre_grouped_count
 *   _range_from    - Normalized start of block range
 *   _range_to      - Normalized end of block range
 *   _order_is      - Sort direction
 *   _page          - Page number (1-based)
 *   _limit         - Page size
 *   _max_page_count - Max page multiplier (from routing context)
 *   _needs_min_block - Whether to extract min_block_num (true for filtered, false for no_filter)
 *
 * RETURNS:
 *   gatherer_result with pagination applied and saturation markers set
 *
 * CURSOR / SATURATION LOGIC:
 *   max_page_limit depends on route type:
 *   - For no_filter (_needs_min_block = false): max_page_limit = total_count
 *     Result: pre_grouped_count == max_page_limit → saturated, but min_block_num = NULL → cursor = range_from
 *   - For filtered (_needs_min_block = true): max_page_limit = _max_page_count * _limit
 *     Result: if pre_grouped_count == max_page_limit → saturated, cursor adjusts
 *             if pre_grouped_count != max_page_limit → more data, cursor = range_from
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_paginate_window(
    _candidates      hafbe_backend.blocksearch_candidates,
    _range_from      INT,
    _range_to        INT,
    _order_is        hafbe_backend.sort_direction,
    _page            INT,
    _limit           INT,
    _max_page_count  INT,
    _needs_min_block BOOLEAN
)
RETURNS hafbe_backend.gatherer_result
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __count           INT := array_length(_candidates.candidate_blocks, 1);
  __total_pages     INT;
  __offset          INT;
  __limit_filter    INT;
  __min_block_num   INT;
  __max_page_limit  INT;
  __paginated_blocks hafbe_backend.gathered_block[];
BEGIN
  -- Handle empty result case
  IF __count IS NULL OR __count = 0 THEN
    -- For empty results, max_page_limit doesn't matter, use 0
    RETURN (
      '{}'::hafbe_backend.gathered_block[],
      0,
      0,
      NULL::INT,
      COALESCE(_candidates.pre_grouped_count, 0),
      0,
      _range_from,
      _range_to
    )::hafbe_backend.gatherer_result;
  END IF;

  -- Determine max_page_limit based on whether min_block is needed
  -- For no_filter (_needs_min_block = false): max_page_limit = total count
  --   This ensures cursor logic returns range_from (pre_grouped_count == max_page_limit)
  -- For filtered (_needs_min_block = true): max_page_limit = _max_page_count * _limit
  --   This enables saturation-based cursor adjustment
  __max_page_limit := CASE
    WHEN _needs_min_block THEN _max_page_count * _limit
    ELSE __count
  END;

  -- Extract min_block_num (last key for cursor) - only for filtered searches
  IF _needs_min_block THEN
    SELECT MIN(block_num)
    INTO __min_block_num
    FROM unnest(_candidates.candidate_blocks) AS b(block_num, operations);
  ELSE
    __min_block_num := NULL;
  END IF;

  -- Calculate pagination parameters
  SELECT total_pages, offset_filter, limit_filter
  INTO __total_pages, __offset, __limit_filter
  FROM hafbe_backend.blocksearch_calculate_pages(__count, _page, _order_is, _limit);

  -- Apply OFFSET + LIMIT pagination
  SELECT array_agg(b ORDER BY
    (CASE WHEN _order_is = 'desc' THEN b.block_num ELSE NULL END) DESC,
    (CASE WHEN _order_is = 'asc' THEN b.block_num ELSE NULL END) ASC
  )
  INTO __paginated_blocks
  FROM (
    SELECT (b.block_num, b.operations)::hafbe_backend.gathered_block AS b
    FROM unnest(_candidates.candidate_blocks) AS b(block_num, operations)
    ORDER BY
      (CASE WHEN _order_is = 'desc' THEN b.block_num ELSE NULL END) DESC,
      (CASE WHEN _order_is = 'asc' THEN b.block_num ELSE NULL END) ASC
    OFFSET __offset
    LIMIT __limit_filter
  ) p;

  -- Build and return final gatherer_result
  RETURN (
    COALESCE(__paginated_blocks, '{}'::hafbe_backend.gathered_block[]),
    COALESCE(__count, 0),
    COALESCE(__total_pages, 0),
    __min_block_num,
    COALESCE(_candidates.pre_grouped_count, __count),
    __max_page_limit,
    _range_from,
    _range_to
  )::hafbe_backend.gatherer_result;
END
$$;

-- ============================================================================
-- SECTION 7: Cache Header Configuration
-- ============================================================================
-- Set appropriate cache headers based on irreversibility.
-- ============================================================================

/*
 * blocksearch_set_cache_headers: Sets cache control headers based on context.
 *
 * If the entire block range is irreversible: cache for 1 year (31536000s)
 * Otherwise: cache for 2 seconds (near-realtime data)
 *
 * PARAMETERS:
 *   _ctx - Routing context (contains is_irreversible flag)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_set_cache_headers(
    _ctx hafbe_backend.blocksearch_context
)
RETURNS VOID
LANGUAGE 'plpgsql'
STABLE
AS
$$
BEGIN
  IF _ctx.is_irreversible THEN
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=31536000"}]', true);
  ELSE
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);
  END IF;
END
$$;

-- ============================================================================
-- SECTION 8: Result Building (Cursor + Enrichment)
-- ============================================================================
-- Cursor calculation and response enrichment.
--
-- CURSOR LOGIC (single point of truth):
--   The cursor indicates where to start the next paginated request.
--   - NULL min_block_num: no results found, keep original range_from
--   - min_block_num = 1: at genesis, cursor = 1
--   - Not saturated (pre_grouped_count != max_page_limit): more data available, keep range_from
--   - Saturated: results capped, cursor = min_block_num - 1 (start before current results)
-- ============================================================================

/*
 * blocksearch_calculate_cursor: Calculates the cursor (next from_block).
 *
 * SINGLE SOURCE OF TRUTH for cursor logic.
 *
 * PARAMETERS:
 *   _gathered - gatherer_result containing all cursor inputs
 *
 * RETURNS:
 *   The cursor value (next from_block for pagination)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_calculate_cursor(
    _gathered hafbe_backend.gatherer_result
)
RETURNS INT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RETURN CASE
    -- No results found: keep original range_from
    WHEN _gathered.min_block_num IS NULL THEN
      _gathered.range_from

    -- At genesis: cursor stays at 1
    WHEN _gathered.min_block_num = 1 THEN
      1

    -- Not saturated (more data available): keep range_from
    WHEN _gathered.pre_grouped_count != _gathered.max_page_limit THEN
      _gathered.range_from

    -- Saturated (results capped): cursor = min_block_num - 1
    ELSE
      _gathered.min_block_num - 1
  END;
END
$$;

/*
 * blocksearch_build_result: Enriches gathered blocks and builds final response.
 *
 * SINGLE POINT OF ENRICHMENT - all gatherer results go through here.
 *
 * PARAMETERS:
 *   _gathered - Raw gatherer_result from the gatherer function
 *   _order_is - Sort direction (for final ordering of enriched blocks)
 *
 * RETURNS:
 *   Final block_history with enriched block data and calculated cursor
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
      '{}'::hafbe_backend.blocksearch[]
    )::hafbe_backend.block_history;
  END IF;

  -- Calculate cursor (single source of truth)
  __cursor_from := hafbe_backend.blocksearch_calculate_cursor(_gathered);

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
    COALESCE(__result, '{}'::hafbe_backend.blocksearch[])
  )::hafbe_backend.block_history;
END
$$;

-- ============================================================================
-- SECTION 9: Complete Execution Pipeline
-- ============================================================================
-- One function to run the ENTIRE block search pipeline.
-- ============================================================================

/*
 * blocksearch_execute: Executes the complete block search pipeline.
 *
 * This is the ONLY function that get_blocks_by_ops needs to call.
 * It runs the full pipeline:
 *   1. Validate (already done by caller - we assume valid inputs)
 *   2. Invoke gatherer (using routing context)
 *   3. Build and enrich final result
 *
 * PARAMETERS:
 *   _ctx - Fully populated and validated routing context
 *
 * RETURNS:
 *   Final block_history response
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_execute(
    _ctx hafbe_backend.blocksearch_context
)
RETURNS hafbe_backend.block_history
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __gathered hafbe_backend.gatherer_result;
BEGIN
  -- Step 1: Invoke gatherer
  __gathered := hafbe_backend.blocksearch_invoke_gatherer(_ctx);

  -- Step 2: Build and enrich final result
  RETURN hafbe_backend.blocksearch_build_result(__gathered, _ctx.order_is);
END
$$;

-- ============================================================================
-- SECTION 10: Debug / Introspection
-- ============================================================================
-- Helper functions for understanding routing decisions.
-- ============================================================================

/*
 * blocksearch_route_description: Returns human-readable route description.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.blocksearch_route_description(
    _route hafbe_backend.blocksearch_route
)
RETURNS TEXT
LANGUAGE 'plpgsql'
IMMUTABLE
AS
$$
BEGIN
  RETURN CASE _route
    WHEN 'no_filter'::hafbe_backend.blocksearch_route THEN
      'No filters applied - returning all blocks in range'
    WHEN 'single_op'::hafbe_backend.blocksearch_route THEN
      'Filtering by single operation type'
    WHEN 'multi_op'::hafbe_backend.blocksearch_route THEN
      'Filtering by multiple operation types'
    WHEN 'key_value'::hafbe_backend.blocksearch_route THEN
      'Filtering by single operation type with key-value match'
    WHEN 'account'::hafbe_backend.blocksearch_route THEN
      'Filtering by account (all operations)'
    WHEN 'account_op'::hafbe_backend.blocksearch_route THEN
      'Filtering by account and single operation type'
    WHEN 'account_multi_op'::hafbe_backend.blocksearch_route THEN
      'Filtering by account and multiple operation types'
    WHEN 'account_key_value'::hafbe_backend.blocksearch_route THEN
      'Filtering by account, single operation type, and key-value match'
    ELSE
      'Unknown route'
  END;
END
$$;

RESET ROLE;

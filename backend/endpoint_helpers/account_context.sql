-- =============================================================================
-- Account Query Context
-- =============================================================================
-- Unified context for account-related API endpoints. Consolidates account
-- resolution, block range handling, pagination validation, cache control,
-- and error handling into a single reusable system.
--
-- -----------------------------------------------------------------------------
-- MANDATORY RULES FOR NEW ACCOUNT ENDPOINTS
-- -----------------------------------------------------------------------------
--
-- 1. USE THE CONTEXT BUILDER — Every endpoint under endpoints/accounts/ MUST
--    call one of the three builder functions.  Direct calls to
--    hafah_backend.get_account_id(), manual set_config('response.headers',...),
--    or hand-rolled validate_limit/validate_negative_page are FORBIDDEN.
--
-- 2. CHOOSE THE CORRECT BUILDER:
--
--    ┌──────────────────────┬────────────────────────────────────────────┐
--    │ Builder              │ When to use                               │
--    ├──────────────────────┼────────────────────────────────────────────┤
--    │ build_simple         │ No pagination, no block range             │
--    │                      │ (get_account, get_account_authority)      │
--    ├──────────────────────┼────────────────────────────────────────────┤
--    │ build_paginated      │ Pagination but no block range             │
--    │                      │ (get_comment_operations,                  │
--    │                      │  get_account_proxies_power)               │
--    ├──────────────────────┼────────────────────────────────────────────┤
--    │ build_block_range    │ Pagination + block range filtering        │
--    │                      │ (get_comment_permlinks)                   │
--    └──────────────────────┴────────────────────────────────────────────┘
--
-- 3. ENDPOINT FILES — Keep the SQL function body minimal:
--      a) Declare OpenAPI parameters (only in the endpoint file).
--      b) Call the corresponding *_endpoint() helper in endpoint_helpers/.
--      c) Return the result.
--    Do NOT add account resolution, cache headers, or pagination
--    validation directly in the endpoint file.
--
-- 4. ENDPOINT HELPER FILES — Create a *_endpoint() wrapper in the
--    appropriate endpoint_helpers/*.sql file.  The wrapper:
--      a) Builds the context via the correct builder.
--      b) Performs endpoint-specific logic (queries, result assembly).
--      c) Returns the typed result.
--
-- 5. VALIDATION FLAGS — Use account_validation_flags to control which
--    validations the builder runs:
--      (require_comment_indexes, validate_block_range, validate_pagination)
--    Set unused flags to FALSE.  All default to TRUE.
--
-- 6. CUSTOM CACHE TTL — Pass _cache_ttl to build_paginated if the endpoint
--    needs a non-default TTL (default = 2 seconds).
--    For block-range endpoints, the builder auto-detects irreversible
--    data and switches between 2s and 31536000s TTL.
--
-- 7. NON-ACCOUNT ENDPOINTS — Endpoints without an account-name parameter
--    (e.g. get_total_wallet_addresses) MUST NOT use account_context_build_*.
--    Instead, use the standalone helpers:
--      - account_context_check_irreversible() + account_context_set_cache_header()
--        for cache logic only.
--
-- 8. CACHE HELPER — Always use account_context_set_cache_header() instead of
--    hand-writing set_config('response.headers', ...).  It accepts an
--    optional _override_ttl for custom TTL values.
--
-- -----------------------------------------------------------------------------
-- USAGE PATTERN:
--   1. Call one of the build_* functions to create a context
--   2. Use the context fields directly in your endpoint helper
--   3. Call the appropriate result builder for the return type
--
-- CONTEXT TYPES:
--   - simple:      For endpoints that just need account validation
--   - paginated:   For paginated endpoints without block range filtering
--   - block_range: For paginated endpoints with block range filtering
-- -----------------------------------------------------------------------------

SET ROLE hafbe_owner;

-- =============================================================================
-- SECTION 1: Type Definitions
-- =============================================================================

/*
 * account_validation_flags: Flags to control which validations run.
 *
 * FIELDS:
 *   require_comment_indexes - Validate comment search indexes are installed
 *   validate_block_range    - Validate block range bounds
 *   validate_pagination     - Validate page and page_size parameters
 */
DROP TYPE IF EXISTS hafbe_backend.account_validation_flags CASCADE;
CREATE TYPE hafbe_backend.account_validation_flags AS (
    require_comment_indexes BOOLEAN,
    validate_block_range    BOOLEAN,
    validate_pagination     BOOLEAN
);

/*
 * account_query_context: Unified context for all account endpoint operations.
 *
 * FIELDS:
 *   account_name     - Original account name from the request
 *   account_id       - Resolved numeric account ID
 *   head_block_num   - Current HAF head block number
 *   irreversible_block - Last irreversible block number
 *   from_block       - Normalized start of block range (NULL if not used)
 *   to_block         - Normalized end of block range (NULL if not used)
 *   page             - Page number (1-based) with default applied
 *   page_size        - Page size with default applied
 *   max_page_size    - Maximum allowed page size for this endpoint
 *   cache_ttl        - Recommended cache TTL in seconds
 *   is_irreversible  - Whether the query range is fully irreversible
 *   total_count      - Total result count (populated by helper)
 *   total_pages      - Total pages available (populated by helper)
 */
DROP TYPE IF EXISTS hafbe_backend.account_query_context CASCADE;
CREATE TYPE hafbe_backend.account_query_context AS (
    account_name          TEXT,
    account_id            INT,
    head_block_num        INT,
    irreversible_block    INT,
    from_block            INT,
    to_block              INT,
    page                  INT,
    page_size             INT,
    max_page_size         INT,
    cache_ttl             INT,
    is_irreversible       BOOLEAN,
    total_count           INT,
    total_pages           INT
);

-- =============================================================================
-- SECTION 2: Default Values
-- =============================================================================

/*
 * account_context_default_page: Default page number.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_default_page()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN 1;
END;
$$;

/*
 * account_context_default_page_size: Default page size.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_default_page_size()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN 100;
END;
$$;

/*
 * account_context_short_cache_ttl: Short cache TTL for live data.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_short_cache_ttl()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN 2;
END;
$$;

/*
 * account_context_long_cache_ttl: Long cache TTL for irreversible data.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_long_cache_ttl()
RETURNS INT LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN 31536000;
END;
$$;

-- =============================================================================
-- SECTION 3: Account Resolution
-- =============================================================================

/*
 * account_context_resolve_account: Resolves an account name to its numeric ID.
 *
 * This is the single point of account resolution for all account endpoints.
 * It calls hafah_backend.get_account_id() which automatically raises a
 * 'Account does not exist' exception if the account is not found.
 *
 * PARAMETERS:
 *   _account_name - The account name to resolve
 *
 * RETURNS: The numeric account ID
 *
 * RAISES: Exception via rest_raise_missing_account if account not found
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_resolve_account(
    _account_name TEXT
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
    RETURN hafah_backend.get_account_id(_account_name, TRUE);
END
$$;

-- =============================================================================
-- SECTION 4: Block Range Handling
-- =============================================================================

/*
 * account_context_convert_block_range: Converts text block range to numeric.
 *
 * Handles both block numbers and timestamps by delegating to
 * hive.convert_to_blocks_range().
 *
 * PARAMETERS:
 *   _from_block - Start of range (block number or timestamp text)
 *   _to_block   - End of range (block number or timestamp text)
 *
 * RETURNS: hive.blocks_range with first_block and last_block fields
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_convert_block_range(
    _from_block TEXT,
    _to_block   TEXT
)
RETURNS hive.blocks_range
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
    RETURN hive.convert_to_blocks_range(_from_block, _to_block);
END
$$;

/*
 * account_context_normalize_block_range: Normalizes and validates block range.
 *
 * Converts NULL values to defaults (genesis for from, head_block for to)
 * and ensures from <= to and to <= head_block_num.
 *
 * PARAMETERS:
 *   _from_block    - Start block number (may be NULL)
 *   _to_block      - End block number (may be NULL)
 *   _head_block    - Current head block number
 *
 * RETURNS: blocksearch_filter_return with normalized range
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_normalize_block_range(
    _from_block INT,
    _to_block   INT,
    _head_block INT
)
RETURNS hafbe_backend.blocksearch_filter_return
LANGUAGE 'plpgsql' IMMUTABLE
SET JIT = OFF
AS
$$
DECLARE
    __genesis_block INT := hafbe_backend.genesis_block_num();
    __to            INT;
    __from          INT;
BEGIN
    __to := CASE
        WHEN _to_block IS NULL THEN _head_block
        WHEN _head_block < _to_block THEN _head_block
        ELSE _to_block
    END;

    __from := CASE
        WHEN _from_block IS NULL THEN __genesis_block
        ELSE _from_block
    END;

    RETURN (NULL, __from, __to)::hafbe_backend.blocksearch_filter_return;
END
$$;

/*
 * account_context_check_irreversible: Checks if a block range is fully
 * within the irreversible block range.
 *
 * PARAMETERS:
 *   _to_block        - End of the query range
 *   _irreversible    - Current irreversible block number
 *
 * RETURNS: TRUE if range is fully irreversible (cacheable long-term)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_check_irreversible(
    _to_block     INT,
    _irreversible INT
)
RETURNS BOOLEAN
LANGUAGE 'plpgsql' IMMUTABLE
AS
$$
BEGIN
    RETURN _to_block <= _irreversible AND _to_block IS NOT NULL;
END
$$;

-- =============================================================================
-- SECTION 5: Pagination Handling
-- =============================================================================

/*
 * account_context_validate_pagination: Validates pagination parameters.
 *
 * Runs all pagination validations in a single call:
 *   - Page size is positive
 *   - Page size does not exceed maximum
 *   - Page number is positive
 *
 * PARAMETERS:
 *   _page_size     - Requested page size
 *   _page          - Requested page number
 *   _max_page_size - Maximum allowed page size
 *
 * RETURNS: VOID, raises exception on validation failure
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_validate_pagination(
    _page_size     INT,
    _page          INT,
    _max_page_size INT
)
RETURNS VOID
LANGUAGE 'plpgsql' IMMUTABLE
AS
$$
BEGIN
    PERFORM hafbe_backend.validate_limit(_page_size, _max_page_size);
    PERFORM hafbe_backend.validate_negative_limit(_page_size);
    PERFORM hafbe_backend.validate_negative_page(_page);
END
$$;

/*
 * account_context_apply_page_defaults: Applies defaults to pagination params.
 *
 * Replaces NULL values with the configured defaults.
 *
 * PARAMETERS:
 *   _page     - Requested page number (may be NULL)
 *   _page_size - Requested page size (may be NULL)
 *
 * RETURNS: (page, page_size) with defaults applied
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_apply_page_defaults(
    _page     INT,
    _page_size INT
)
RETURNS RECORD
LANGUAGE 'plpgsql' IMMUTABLE
AS
$$
DECLARE
    __result RECORD;
BEGIN
    SELECT
        COALESCE(_page, hafbe_backend.account_context_default_page()),
        COALESCE(_page_size, hafbe_backend.account_context_default_page_size())
    INTO __result;
    RETURN __result;
END
$$;

/*
 * account_context_calculate_total_pages: Calculates total pages from count.
 *
 * PARAMETERS:
 *   _total_count - Total number of items
 *   _page_size   - Page size
 *
 * RETURNS: Total number of pages
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_calculate_total_pages(
    _total_count INT,
    _page_size   INT
)
RETURNS INT
LANGUAGE 'plpgsql' IMMUTABLE
AS
$$
BEGIN
    RETURN hafah_backend.total_pages(_total_count, _page_size);
END
$$;

-- =============================================================================
-- SECTION 6: Cache Control
-- =============================================================================

/*
 * account_context_set_cache_header: Sets the appropriate Cache-Control header.
 *
 * Uses long TTL for irreversible data, short TTL otherwise.
 *
 * PARAMETERS:
 *   _is_irreversible - Whether the query result is fully irreversible
 *
 * RETURNS: VOID (side effect: sets response.headers config)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_set_cache_header(
    _is_irreversible BOOLEAN,
    _override_ttl    INT DEFAULT NULL
)
RETURNS VOID
LANGUAGE 'plpgsql' VOLATILE
AS
$$
DECLARE
    __ttl INT;
BEGIN
    __ttl := COALESCE(
        _override_ttl,
        CASE
            WHEN _is_irreversible THEN hafbe_backend.account_context_long_cache_ttl()
            ELSE hafbe_backend.account_context_short_cache_ttl()
        END
    );

    PERFORM set_config(
        'response.headers',
        '[{"Cache-Control": "public, max-age=' || __ttl || '"}]',
        true
    );
END
$$;

-- =============================================================================
-- SECTION 7: Context Builder Functions
-- =============================================================================

/*
 * account_context_build_simple: Builds context for simple account endpoints.
 *
 * Use this for endpoints that only need account validation without
 * pagination or block range filtering (get_account, get_account_authority).
 *
 * PARAMETERS:
 *   _account_name - The account name from the request
 *
 * RETURNS: account_query_context with account resolved and ready to use
 *
 * EXAMPLE:
 *   _ctx := hafbe_backend.account_context_build_simple("account-name");
 *   -- Now use _ctx.account_id, _ctx.account_name, etc.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_build_simple(
    _account_name TEXT
)
RETURNS hafbe_backend.account_query_context
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
    __account_id         INT;
    __head_block         INT;
    __irreversible_block INT;
    __ctx                hafbe_backend.account_query_context;
BEGIN
    __account_id         := hafbe_backend.account_context_resolve_account(_account_name);
    __head_block         := hafbe_backend.get_haf_head_block();
    __irreversible_block := hive.app_get_irreversible_block();

    __ctx.account_name       := _account_name;
    __ctx.account_id         := __account_id;
    __ctx.head_block_num     := __head_block;
    __ctx.irreversible_block := __irreversible_block;
    __ctx.from_block         := NULL;
    __ctx.to_block           := NULL;
    __ctx.page               := NULL;
    __ctx.page_size          := NULL;
    __ctx.max_page_size      := NULL;
    __ctx.cache_ttl          := hafbe_backend.account_context_short_cache_ttl();
    __ctx.is_irreversible    := FALSE;
    __ctx.total_count        := NULL;
    __ctx.total_pages        := NULL;

    PERFORM hafbe_backend.account_context_set_cache_header(FALSE);

    RETURN __ctx;
END
$$;

/*
 * account_context_build_paginated: Builds context for paginated account endpoints.
 *
 * Use this for endpoints that need pagination but no block range filtering
 * (get_comment_operations).
 *
 * PARAMETERS:
 *   _account_name  - The account name from the request
 *   _page          - Page number (1-based, may be NULL for default)
 *   _page_size     - Page size (may be NULL for default)
 *   _max_page_size - Maximum allowed page size
 *   _flags         - Validation flags (optional, all enabled by default)
 *   _cache_ttl     - Custom cache TTL in seconds (optional, default=2)
 *
 * RETURNS: account_query_context with all fields populated and validated
 *
 * EXAMPLE:
 *   _ctx := hafbe_backend.account_context_build_paginated(
 *     "account-name", "page", "page-size", 10000
 *   );
 *
 *   -- With custom cache TTL:
 *   _ctx := hafbe_backend.account_context_build_paginated(
 *     "account-name", "page", "page-size", 10000,
 *     NULL, 5
 *   );
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_build_paginated(
    _account_name  TEXT,
    _page          INT,
    _page_size     INT,
    _max_page_size INT,
    _flags         hafbe_backend.account_validation_flags DEFAULT NULL,
    _cache_ttl     INT DEFAULT NULL
)
RETURNS hafbe_backend.account_query_context
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
    __account_id         INT;
    __head_block         INT;
    __irreversible_block INT;
    __ctx                hafbe_backend.account_query_context;
    __page_defaults      RECORD;
    __flags              hafbe_backend.account_validation_flags;
    __ttl                INT;
BEGIN
    __flags := COALESCE(_flags, (TRUE, TRUE, TRUE)::hafbe_backend.account_validation_flags);
    __ttl   := COALESCE(_cache_ttl, hafbe_backend.account_context_short_cache_ttl());

    __account_id         := hafbe_backend.account_context_resolve_account(_account_name);
    __head_block         := hafbe_backend.get_haf_head_block();
    __irreversible_block := hive.app_get_irreversible_block();

    __page_defaults := hafbe_backend.account_context_apply_page_defaults(_page, _page_size);

    __ctx.account_name       := _account_name;
    __ctx.account_id         := __account_id;
    __ctx.head_block_num     := __head_block;
    __ctx.irreversible_block := __irreversible_block;
    __ctx.from_block         := NULL;
    __ctx.to_block           := NULL;
    __ctx.page               := __page_defaults.column1;
    __ctx.page_size          := __page_defaults.column2;
    __ctx.max_page_size      := _max_page_size;
    __ctx.total_count        := NULL;
    __ctx.total_pages        := NULL;

    IF __flags.validate_pagination THEN
        PERFORM hafbe_backend.account_context_validate_pagination(
            __ctx.page_size, __ctx.page, __ctx.max_page_size
        );
    END IF;

    IF __flags.require_comment_indexes THEN
        PERFORM hafbe_backend.validate_comment_search_indexes();
    END IF;

    __ctx.is_irreversible := FALSE;
    __ctx.cache_ttl       := __ttl;

    PERFORM hafbe_backend.account_context_set_cache_header(FALSE, __ttl);

    RETURN __ctx;
END;
$$;

/*
 * account_context_build_block_range: Builds context for block-range endpoints.
 *
 * Use this for endpoints that need both pagination and block range filtering
 * (get_comment_permlinks).
 *
 * PARAMETERS:
 *   _account_name  - The account name from the request
 *   _from_block    - Start of range (block number or timestamp text)
 *   _to_block      - End of range (block number or timestamp text)
 *   _page          - Page number (1-based, may be NULL for default)
 *   _page_size     - Page size (may be NULL for default)
 *   _max_page_size - Maximum allowed page size
 *   _flags         - Validation flags (optional, all enabled by default)
 *
 * RETURNS: account_query_context with all fields populated and validated
 *
 * EXAMPLE:
 *   _ctx := hafbe_backend.account_context_build_block_range(
 *     "account-name", "from-block", "to-block",
 *     "page", "page-size", 100
 *   );
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_build_block_range(
    _account_name  TEXT,
    _from_block    TEXT,
    _to_block      TEXT,
    _page          INT,
    _page_size     INT,
    _max_page_size INT,
    _flags         hafbe_backend.account_validation_flags DEFAULT NULL
)
RETURNS hafbe_backend.account_query_context
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
    __account_id         INT;
    __head_block         INT;
    __irreversible_block INT;
    __block_range_raw    hive.blocks_range;
    __block_range_norm   hafbe_backend.blocksearch_filter_return;
    __ctx                hafbe_backend.account_query_context;
    __page_defaults      RECORD;
    __flags              hafbe_backend.account_validation_flags;
BEGIN
    __flags := COALESCE(_flags, (TRUE, TRUE, TRUE)::hafbe_backend.account_validation_flags);

    __account_id         := hafbe_backend.account_context_resolve_account(_account_name);
    __head_block         := hafbe_backend.get_haf_head_block();
    __irreversible_block := hive.app_get_irreversible_block();

    __block_range_raw  := hafbe_backend.account_context_convert_block_range(_from_block, _to_block);
    __block_range_norm := hafbe_backend.account_context_normalize_block_range(
        __block_range_raw.first_block, __block_range_raw.last_block, __head_block
    );

    __page_defaults := hafbe_backend.account_context_apply_page_defaults(_page, _page_size);

    __ctx.account_name       := _account_name;
    __ctx.account_id         := __account_id;
    __ctx.head_block_num     := __head_block;
    __ctx.irreversible_block := __irreversible_block;
    __ctx.from_block         := __block_range_norm.from_block;
    __ctx.to_block           := __block_range_norm.to_block;
    __ctx.page               := __page_defaults.column1;
    __ctx.page_size          := __page_defaults.column2;
    __ctx.max_page_size      := _max_page_size;
    __ctx.total_count        := NULL;
    __ctx.total_pages        := NULL;

    IF __flags.validate_pagination THEN
        PERFORM hafbe_backend.account_context_validate_pagination(
            __ctx.page_size, __ctx.page, __ctx.max_page_size
        );
    END IF;

    IF __flags.require_comment_indexes THEN
        PERFORM hafbe_backend.validate_comment_search_indexes();
    END IF;

    IF __flags.validate_block_range THEN
        PERFORM hafbe_backend.validate_block_num_too_high(
            __block_range_raw.first_block, __head_block
        );
    END IF;

    __ctx.is_irreversible := hafbe_backend.account_context_check_irreversible(
        __block_range_raw.last_block, __irreversible_block
    );
    __ctx.cache_ttl := CASE
        WHEN __ctx.is_irreversible THEN hafbe_backend.account_context_long_cache_ttl()
        ELSE hafbe_backend.account_context_short_cache_ttl()
    END;

    PERFORM hafbe_backend.account_context_set_cache_header(__ctx.is_irreversible);

    RETURN __ctx;
END
$$;

-- =============================================================================
-- SECTION 8: Result Builders
-- =============================================================================

/*
 * account_context_build_operation_history: Builds operation_history response.
 *
 * Unified result builder for operation history endpoints. Handles COALESCE
 * and type casting consistently.
 *
 * PARAMETERS:
 *   _total_count  - Total number of operations
 *   _total_pages  - Total number of pages
 *   _operations   - Array of operation records
 *
 * RETURNS: operation_history ready to return from endpoint
 */
CREATE OR REPLACE FUNCTION hafbe_backend.account_context_build_operation_history(
    _total_count INT,
    _total_pages INT,
    _operations  hafbe_backend.operation[]
)
RETURNS hafbe_backend.operation_history
LANGUAGE 'plpgsql' IMMUTABLE
AS
$$
BEGIN
    RETURN (
        COALESCE(_total_count, 0),
        COALESCE(_total_pages, 0),
        COALESCE(_operations, '{}'::hafbe_backend.operation[])
    )::hafbe_backend.operation_history;
END
$$;

RESET ROLE;

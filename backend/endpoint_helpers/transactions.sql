-- =============================================================================
-- Transaction Statistics Helper Functions
-- =============================================================================
-- Functions for retrieving and aggregating transaction statistics
-- at various granularities (daily, monthly, yearly).
-- =============================================================================

SET ROLE hafbe_owner;

-- =============================================================================
-- SECTION 1: Type Definitions
-- =============================================================================

/*
 * transaction_stats: Transaction statistics for a time period (API output format).
 *
 * FIELDS:
 *   date           - Period timestamp (start of day/month/year)
 *   trx_count      - Total transactions in period
 *   avg_trx        - Average transactions per block
 *   min_trx        - Minimum transactions in a single block
 *   max_trx        - Maximum transactions in a single block
 *   last_block_num - Last block number in the period
 */
DROP TYPE IF EXISTS hafbe_backend.transaction_stats CASCADE;
CREATE TYPE hafbe_backend.transaction_stats AS (
    date           TIMESTAMP,
    trx_count      INT,
    avg_trx        INT,
    min_trx        INT,
    max_trx        INT,
    last_block_num INT
);

/*
 * trx_stats: Transaction statistics for a time period (internal format).
 *
 * Similar to transaction_stats but with count_blocks instead of avg_trx.
 * Used for aggregation before calculating averages.
 *
 * FIELDS:
 *   date           - Period timestamp
 *   trx_count      - Total transactions in period
 *   count_blocks   - Number of blocks in period
 *   min_trx        - Minimum transactions in a single block
 *   max_trx        - Maximum transactions in a single block
 *   last_block_num - Last block number in the period
 */
DROP TYPE IF EXISTS hafbe_backend.trx_stats CASCADE;
CREATE TYPE hafbe_backend.trx_stats AS (
    date           TIMESTAMP,
    trx_count      INT,
    count_blocks   INT,
    min_trx        INT,
    max_trx        INT,
    last_block_num INT
);

-- =============================================================================
-- SECTION 2: Aggregation Helper Functions
-- =============================================================================

/*
 * transaction_stats_by_year: Aggregates monthly stats into yearly statistics.
 *
 * Reads from pre-computed monthly stats table and groups by year.
 * Used by get_transaction_stats when granularity is 'yearly'.
 *
 * PARAMETERS:
 *   _from - Start timestamp (truncated to year)
 *   _to   - End timestamp (truncated to year)
 *
 * RETURNS: Set of trx_stats records grouped by year
 */
CREATE OR REPLACE FUNCTION hafbe_backend.transaction_stats_by_year(
    _from TIMESTAMP,
    _to   TIMESTAMP
)
RETURNS SETOF hafbe_backend.trx_stats
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN QUERY
    WITH get_year AS (
      SELECT
        trx_count,
        count_blocks,
        min_trx,
        max_trx,
        last_block_num,
        updated_at,
        DATE_TRUNC('year', updated_at) AS by_year
      FROM hafbe_app.transaction_stats_by_month
      WHERE DATE_TRUNC('year', updated_at) BETWEEN _from AND _to
    )
    SELECT
      by_year,
      SUM(trx_count)::INT,
      SUM(count_blocks)::INT,
      MIN(min_trx)::INT,
      MAX(max_trx)::INT,
      MAX(last_block_num) AS last_block_num
    FROM get_year
    GROUP BY by_year;
END
$$;

/*
 * get_transaction_stats: Retrieves transaction stats at specified granularity.
 *
 * Dispatcher function that reads from the appropriate pre-computed stats table
 * based on the requested granularity.
 *
 * PARAMETERS:
 *   _granularity - Time granularity: 'daily', 'monthly', or 'yearly'
 *   _from        - Start timestamp
 *   _to          - End timestamp
 *
 * RETURNS: Set of trx_stats records for the time range
 *
 * DATA SOURCES:
 *   - daily:   hafbe_app.transaction_stats_by_day
 *   - monthly: hafbe_app.transaction_stats_by_month
 *   - yearly:  Computed from monthly via transaction_stats_by_year()
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_transaction_stats(
    _granularity hafbe_backend.granularity,
    _from        TIMESTAMP,
    _to          TIMESTAMP
)
RETURNS SETOF hafbe_backend.trx_stats
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  IF _granularity = 'daily' THEN
    RETURN QUERY
      SELECT
        bh.updated_at,
        bh.trx_count,
        bh.count_blocks,
        bh.min_trx,
        bh.max_trx,
        bh.last_block_num
      FROM hafbe_app.transaction_stats_by_day bh
      WHERE bh.updated_at BETWEEN _from AND _to;

  ELSIF _granularity = 'monthly' THEN
    RETURN QUERY
      SELECT
        bh.updated_at,
        bh.trx_count,
        bh.count_blocks,
        bh.min_trx,
        bh.max_trx,
        bh.last_block_num
      FROM hafbe_app.transaction_stats_by_month bh
      WHERE bh.updated_at BETWEEN _from AND _to;

  ELSIF _granularity = 'yearly' THEN
    RETURN QUERY
      SELECT
        bh.date,
        bh.trx_count,
        bh.count_blocks,
        bh.min_trx,
        bh.max_trx,
        bh.last_block_num
      FROM hafbe_backend.transaction_stats_by_year(_from, _to) bh;

  ELSE
    RAISE EXCEPTION 'Unsupported granularity: %', _granularity;
  END IF;
END
$$;

-- =============================================================================
-- SECTION 3: Main API Function
-- =============================================================================

/*
 * get_transaction_aggregation: Main function for transaction statistics API.
 *
 * Returns transaction statistics for a block range at the specified granularity.
 * Fills gaps in the time series with zero values for periods without data.
 *
 * PARAMETERS:
 *   _granularity - Time granularity: 'daily', 'monthly', or 'yearly'
 *   _direction   - Sort direction: 'asc' or 'desc'
 *   _from_block  - Starting block number (NULL = genesis)
 *   _to_block    - Ending block number (NULL = current head)
 *
 * RETURNS: Set of transaction_stats records covering the time range
 *
 * PROCESSING STEPS:
 *   1. Convert block range to timestamp range
 *   2. Generate complete time series for the period
 *   3. Left join with actual stats (gaps become NULL)
 *   4. Fill missing last_block_num by finding nearest block
 *   5. Calculate avg_trx from trx_count and count_blocks
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_transaction_aggregation(
    _granularity hafbe_backend.granularity,
    _direction   hafbe_backend.sort_direction,
    _from_block  INT,
    _to_block    INT
)
RETURNS SETOF hafbe_backend.transaction_stats
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  _ctx hafbe_backend.period_context := hafbe_backend.resolve_period_context(_granularity, _from_block, _to_block);
BEGIN
  RETURN QUERY (
    WITH date_series AS (
      SELECT hafbe_backend.generate_time_buckets(_ctx) AS date
    ),
    get_daily_aggregation AS MATERIALIZED (
      SELECT
        bh.date,
        bh.trx_count,
        bh.count_blocks,
        bh.min_trx,
        bh.max_trx,
        bh.last_block_num
      FROM hafbe_backend.get_transaction_stats(_granularity, _ctx.from_timestamp, _ctx.to_timestamp) bh
    ),
    transaction_records AS (
      SELECT
        ds.date,
        COALESCE(bh.trx_count, 0)    AS trx_count,
        COALESCE(bh.count_blocks, 0) AS count_blocks,
        COALESCE(bh.min_trx, 0)      AS min_trx,
        COALESCE(bh.max_trx, 0)      AS max_trx,
        bh.last_block_num            AS last_block_num
      FROM date_series ds
      LEFT JOIN get_daily_aggregation bh ON ds.date = bh.date
    ),
    join_missing_block AS (
      SELECT
        fb.date,
        fb.trx_count,
        fb.count_blocks,
        fb.min_trx,
        fb.max_trx,
        COALESCE(fb.last_block_num, jl.last_block_num) AS last_block_num
      FROM transaction_records fb
      LEFT JOIN LATERAL (
        SELECT hafbe_backend.find_nearest_block_before(fb.date + _ctx.one_period) AS last_block_num
      ) jl ON fb.last_block_num IS NULL
    )
    SELECT
      hafbe_backend.adjust_to_period_end(fb.date, _ctx.one_period) AS adjusted_date,
      fb.trx_count::INT,
      (CASE WHEN fb.count_blocks = 0 THEN 0 ELSE (fb.trx_count / fb.count_blocks) END)::INT AS avg_trx,
      fb.min_trx::INT,
      fb.max_trx::INT,
      fb.last_block_num::INT
    FROM join_missing_block fb
    ORDER BY
      (CASE WHEN _direction = 'desc' THEN fb.date ELSE NULL END) DESC,
      (CASE WHEN _direction = 'asc' THEN fb.date ELSE NULL END) ASC
  );
END
$$;

RESET ROLE;

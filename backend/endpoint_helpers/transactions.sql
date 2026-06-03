-- =============================================================================
-- Transaction Statistics Helper Functions
-- =============================================================================
-- Functions for retrieving and aggregating transaction statistics
-- at various granularities (daily, monthly, yearly).
-- =============================================================================

SET ROLE hafbe_owner;

-- =============================================================================
-- SECTION 1: Internal Dispatcher (transaction count rollup)
-- =============================================================================
-- get_transaction_stats + transaction_stats_by_year read from pre-computed
-- transaction_stats_by_day/_by_month tables and return flat trx_stats rows.
-- These are used internally by get_operation_group_aggregation to populate
-- total_transactions in the final response.
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
-- SECTION 3: Unified Aggregation (operation-group dimension)
-- =============================================================================
-- Single aggregation path for all granularities (daily/monthly/yearly).
-- Always returns operation_group_stats with per-group breakdown.
-- The `operation-group` parameter acts purely as a filter; NULL = all groups.
-- =============================================================================

/*
 * operation_group_stats_by_year: Aggregates monthly per-group stats into yearly.
 *
 * Reads pre-computed monthly per-op-type stats, maps to groups, and sums.
 * Used by get_operation_group_stats when granularity is 'yearly'.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.operation_group_stats_by_year(
    _from     TIMESTAMP,
    _to       TIMESTAMP,
    _groups   hafbe_backend.operation_group[] DEFAULT NULL
)
RETURNS SETOF hafbe_backend.op_group_stats_flat
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN QUERY
    SELECT
      DATE_TRUNC('year', s.updated_at)::TIMESTAMP AS date,
      hafbe_backend.get_operation_group(s.op_type_id) AS op_group,
      SUM(s.op_count)::BIGINT       AS op_count,
      MAX(s.last_block_num)::INT    AS last_block_num
    FROM hafbe_app.operation_type_stats_by_month s
    WHERE DATE_TRUNC('year', s.updated_at) BETWEEN _from AND _to
      AND (_groups IS NULL OR hafbe_backend.get_operation_group(s.op_type_id) = ANY(_groups))
    GROUP BY DATE_TRUNC('year', s.updated_at), hafbe_backend.get_operation_group(s.op_type_id);
END
$$;

/*
 * get_operation_group_stats: Retrieves per-group operation counts at specified granularity.
 *
 * Dispatcher function that reads from the appropriate pre-computed table
 * based on the requested granularity. Maps op_type_id to operation_group on the fly.
 *
 * DATA SOURCES:
 *   - daily:   hafbe_app.operation_type_stats_by_day
 *   - monthly: hafbe_app.operation_type_stats_by_month
 *   - yearly:  Computed from monthly via operation_group_stats_by_year()
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_operation_group_stats(
    _granularity hafbe_backend.granularity,
    _from        TIMESTAMP,
    _to          TIMESTAMP,
    _groups      hafbe_backend.operation_group[] DEFAULT NULL
)
RETURNS SETOF hafbe_backend.op_group_stats_flat
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  IF _granularity = 'daily' THEN
    RETURN QUERY
      SELECT
        s.updated_at,
        hafbe_backend.get_operation_group(s.op_type_id) AS op_group,
        SUM(s.op_count)::BIGINT AS op_count,
        MAX(s.last_block_num)::INT AS last_block_num
      FROM hafbe_app.operation_type_stats_by_day s
      WHERE s.updated_at BETWEEN _from AND _to
        AND (_groups IS NULL OR hafbe_backend.get_operation_group(s.op_type_id) = ANY(_groups))
      GROUP BY s.updated_at, hafbe_backend.get_operation_group(s.op_type_id);

  ELSIF _granularity = 'monthly' THEN
    RETURN QUERY
      SELECT
        s.updated_at,
        hafbe_backend.get_operation_group(s.op_type_id) AS op_group,
        SUM(s.op_count)::BIGINT AS op_count,
        MAX(s.last_block_num)::INT AS last_block_num
      FROM hafbe_app.operation_type_stats_by_month s
      WHERE s.updated_at BETWEEN _from AND _to
        AND (_groups IS NULL OR hafbe_backend.get_operation_group(s.op_type_id) = ANY(_groups))
      GROUP BY s.updated_at, hafbe_backend.get_operation_group(s.op_type_id);

  ELSIF _granularity = 'yearly' THEN
    RETURN QUERY
      SELECT *
      FROM hafbe_backend.operation_group_stats_by_year(_from, _to, _groups);

  ELSE
    RAISE EXCEPTION 'Unsupported granularity: %', _granularity;
  END IF;
END
$$;

/*
 * get_operation_group_aggregation: Unified aggregation function for the
 * transaction-statistics endpoint.
 *
 * Always returns one row per period with:
 *   - total_transactions (from transaction_stats rollup)
 *   - total_operations   (sum across groups)
 *   - groups             (nested array of {group, op_count, trx_count})
 *   - last_block_num
 *
 * The same CTE pipeline is used for daily/monthly/yearly granularities;
 * the granularity dispatch happens inside get_operation_group_stats and
 * get_transaction_stats.
 *
 * PARAMETERS:
 *   _granularity - 'daily' | 'monthly' | 'yearly'
 *   _direction   - 'asc' | 'desc'
 *   _from_block  - lower bound block number
 *   _to_block    - upper bound block number
 *   _groups      - optional filter; NULL = include all groups
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_operation_group_aggregation(
    _granularity hafbe_backend.granularity,
    _direction   hafbe_backend.sort_direction,
    _from_block  INT,
    _to_block    INT,
    _groups      hafbe_backend.operation_group[] DEFAULT NULL
)
RETURNS SETOF hafbe_backend.operation_group_stats
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  __from                INT;
  __to                  INT;
  __from_timestamp      TIMESTAMP;
  __to_timestamp        TIMESTAMP;
  __granularity         TEXT;
  __one_period          INTERVAL;
  __hafbe_current_block INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from_block, _to_block, __hafbe_current_block);

  __granularity := (
    CASE
      WHEN _granularity = 'daily'   THEN 'day'
      WHEN _granularity = 'monthly' THEN 'month'
      WHEN _granularity = 'yearly'  THEN 'year'
      ELSE NULL
    END
  );

  __from_timestamp := DATE_TRUNC(
    __granularity,
    (SELECT b.created_at FROM hive.blocks_view b WHERE b.num = __from)::TIMESTAMP
  );
  __to_timestamp := DATE_TRUNC(
    __granularity,
    (SELECT b.created_at FROM hive.blocks_view b WHERE b.num = __to)::TIMESTAMP
  );

  __one_period := ('1 ' || __granularity)::INTERVAL;

  RETURN QUERY (
    WITH date_series AS (
      SELECT generate_series(__from_timestamp, __to_timestamp, __one_period) AS period
    ),

    group_stats AS MATERIALIZED (
      SELECT s.date AS period, s.op_group, s.op_count, s.last_block_num
      FROM hafbe_backend.get_operation_group_stats(_granularity, __from_timestamp, __to_timestamp, _groups) s
    ),

    period_groups AS (
      SELECT
        gs.period,
        SUM(gs.op_count)::BIGINT AS total_operations,
        ARRAY_AGG(
          ROW(gs.op_group, gs.op_count, 0)::hafbe_backend.period_op_group_count
          ORDER BY gs.op_group
        ) AS groups,
        MAX(gs.last_block_num)::INT AS last_block_num
      FROM group_stats gs
      GROUP BY gs.period
    ),

    trx_stats AS MATERIALIZED (
      SELECT
        ts.date::TIMESTAMP AS period,
        ts.trx_count::BIGINT AS trx_count,
        ts.last_block_num
      FROM hafbe_backend.get_transaction_stats(_granularity, __from_timestamp, __to_timestamp) ts
    ),

    assembled AS (
      SELECT
        ds.period,
        COALESCE(ts.trx_count, 0)        AS total_transactions,
        COALESCE(pg.total_operations, 0) AS total_operations,
        COALESCE(pg.groups, ARRAY[]::hafbe_backend.period_op_group_count[]) AS groups,
        COALESCE(pg.last_block_num, ts.last_block_num) AS last_block_num
      FROM date_series ds
      LEFT JOIN period_groups pg ON pg.period = ds.period
      LEFT JOIN trx_stats  ts ON ts.period = ds.period
    ),

    with_block AS (
      SELECT
        a.period,
        a.total_transactions,
        a.total_operations,
        a.groups,
        COALESCE(a.last_block_num, jl.last_block_num) AS last_block_num
      FROM assembled a
      LEFT JOIN LATERAL (
        SELECT b.num AS last_block_num
        FROM hive.blocks_view b
        WHERE b.created_at <= a.period + __one_period
        ORDER BY b.created_at DESC
        LIMIT 1
      ) jl ON a.last_block_num IS NULL
    )

    SELECT
      LEAST(wb.period + __one_period, CURRENT_TIMESTAMP)::TIMESTAMP AS date,
      wb.total_transactions,
      wb.total_operations,
      wb.groups,
      wb.last_block_num
    FROM with_block wb
    ORDER BY
      (CASE WHEN _direction = 'desc' THEN wb.period ELSE NULL END) DESC,
      (CASE WHEN _direction = 'asc'  THEN wb.period ELSE NULL END) ASC
  );
END
$$;

RESET ROLE;

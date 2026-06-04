SET ROLE hafbe_owner;

DROP TYPE IF EXISTS hafbe_backend.period_context CASCADE;
CREATE TYPE hafbe_backend.period_context AS (
  from_block       INT,
  to_block         INT,
  from_timestamp   TIMESTAMP,
  to_timestamp     TIMESTAMP,
  granularity_text TEXT,
  one_period       INTERVAL
);

CREATE OR REPLACE FUNCTION hafbe_backend.resolve_period_context(
    _granularity hafbe_backend.granularity,
    _from_block  INT,
    _to_block    INT
)
RETURNS hafbe_backend.period_context
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  __from                INT;
  __to                  INT;
  __from_timestamp      TIMESTAMP;
  __to_timestamp        TIMESTAMP;
  __granularity_text    TEXT;
  __one_period          INTERVAL;
  __hafbe_current_block INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
BEGIN
  SELECT from_block, to_block
  INTO __from, __to
  FROM hafbe_backend.blocksearch_range(_from_block, _to_block, __hafbe_current_block);

  __granularity_text := (
    CASE
      WHEN _granularity = 'daily'   THEN 'day'
      WHEN _granularity = 'monthly' THEN 'month'
      WHEN _granularity = 'yearly'  THEN 'year'
      ELSE NULL
    END
  );

  __from_timestamp := DATE_TRUNC(
    __granularity_text,
    (SELECT b.created_at FROM hive.blocks_view b WHERE b.num = __from)::TIMESTAMP
  );
  __to_timestamp := DATE_TRUNC(
    __granularity_text,
    (SELECT b.created_at FROM hive.blocks_view b WHERE b.num = __to)::TIMESTAMP
  );

  __one_period := ('1 ' || __granularity_text)::INTERVAL;

  RETURN (__from, __to, __from_timestamp, __to_timestamp, __granularity_text, __one_period)::hafbe_backend.period_context;
END
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.adjust_to_period_end(
    _period_start TIMESTAMP,
    _one_period   INTERVAL
)
RETURNS TIMESTAMP
LANGUAGE 'sql' STABLE
AS
$$
  SELECT LEAST(_period_start + _one_period, CURRENT_TIMESTAMP)::TIMESTAMP;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.find_nearest_block_before(
    _before_timestamp TIMESTAMP
)
RETURNS INT
LANGUAGE 'sql' STABLE
AS
$$
  SELECT b.num
  FROM hive.blocks_view b
  WHERE b.created_at <= _before_timestamp
  ORDER BY b.created_at DESC
  LIMIT 1;
$$;

-- =============================================================================
-- SECTION 2: Pagination & List Context
-- =============================================================================

DROP TYPE IF EXISTS hafbe_backend.list_context CASCADE;
CREATE TYPE hafbe_backend.list_context AS (
  block_range    hive.blocks_range,
  head_block_num INT,
  offset_val     INT,
  page_size      INT,
  page           INT
);

CREATE OR REPLACE FUNCTION hafbe_backend.resolve_list_context(
    _from_block TEXT,
    _to_block   TEXT,
    _page_size  INT,
    _page       INT,
    _max_limit  INT DEFAULT 1000
)
RETURNS hafbe_backend.list_context
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  _block_range    hive.blocks_range := hive.convert_to_blocks_range(_from_block, _to_block);
  _head_block_num INT               := hafbe_backend.get_hafbe_head_block();
BEGIN
  PERFORM hafbe_backend.validate_limit(_page_size, _max_limit);
  PERFORM hafbe_backend.validate_negative_limit(_page_size);
  PERFORM hafbe_backend.validate_negative_page(_page);
  IF _block_range.first_block IS NOT NULL THEN
    PERFORM hafbe_backend.validate_block_num_too_high(_block_range.first_block, _head_block_num);
  END IF;

  RETURN (_block_range, _head_block_num, ((_page - 1) * _page_size), _page_size, _page)::hafbe_backend.list_context;
END
$$;

-- =============================================================================
-- SECTION 3: Unified Period-Pagination Context
-- =============================================================================

DROP TYPE IF EXISTS hafbe_backend.period_list_context CASCADE;
CREATE TYPE hafbe_backend.period_list_context AS (
  period    hafbe_backend.period_context,
  list      hafbe_backend.list_context,
  direction hafbe_backend.sort_direction
);

CREATE OR REPLACE FUNCTION hafbe_backend.resolve_period_list_context(
    _granularity hafbe_backend.granularity,
    _direction   hafbe_backend.sort_direction,
    _from_block  TEXT,
    _to_block    TEXT,
    _page_size   INT,
    _page        INT,
    _max_limit   INT DEFAULT 1000
)
RETURNS hafbe_backend.period_list_context
LANGUAGE 'plpgsql'
STABLE
AS
$$
DECLARE
  __list_ctx hafbe_backend.list_context;
BEGIN
  __list_ctx := hafbe_backend.resolve_list_context(_from_block, _to_block, _page_size, _page, _max_limit);

  RETURN (
    hafbe_backend.resolve_period_context(_granularity, __list_ctx.block_range.first_block, __list_ctx.block_range.last_block),
    __list_ctx,
    COALESCE(_direction, 'desc')
  )::hafbe_backend.period_list_context;
END
$$;

-- =============================================================================
-- SECTION 4: Total Count & Pages Helpers
-- =============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.compute_total_pages(
    _total_count INT,
    _page_size   INT
)
RETURNS INT
LANGUAGE 'sql' STABLE
AS
$$
  SELECT COALESCE(CEIL(_total_count::NUMERIC / _page_size::NUMERIC), 0)::INT;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.validate_and_compute_pages(
    _total_count INT,
    _page_size   INT,
    _page        INT
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  _total_pages INT;
BEGIN
  _total_pages := hafbe_backend.compute_total_pages(_total_count, _page_size);
  PERFORM hafbe_backend.validate_page(_page, _total_pages);
  RETURN _total_pages;
END
$$;

-- =============================================================================
-- SECTION 5: Generic Time-Series Aggregation Helpers
-- =============================================================================
-- These helpers unify the time-bucket generation and gap-filling pattern
-- used by transaction statistics, witness vote timeline, and proposal stats.
-- =============================================================================

/*
 * generate_time_buckets: Generates a complete series of time buckets for a period.
 *
 * Uses generate_series to create one row per time period (day/month/year)
 * covering the entire range. This ensures gaps in the data are represented
 * as NULL rows that can be filled with default values.
 *
 * PARAMETERS:
 *   _ctx - period_context containing from_timestamp, to_timestamp, and one_period
 *
 * RETURNS: Set of TIMESTAMP values, one for each period start
 *
 * USAGE: Used as the base CTE in all time-series aggregation queries
 */
CREATE OR REPLACE FUNCTION hafbe_backend.generate_time_buckets(
    _ctx hafbe_backend.period_context
)
RETURNS SETOF TIMESTAMP
LANGUAGE 'sql' STABLE
AS
$$
  SELECT generate_series(_ctx.from_timestamp, _ctx.to_timestamp, _ctx.one_period)::TIMESTAMP;
$$;

/*
 * get_order_by_clause: Generates the ORDER BY clause for time-series queries.
 *
 * Uses the CASE-WHEN pattern to avoid dynamic SQL while supporting both
 * ascending and descending sort directions.
 *
 * PARAMETERS:
 *   _direction - Sort direction: 'asc' or 'desc'
 *   _column    - Column name to sort by (default: 'date')
 *
 * RETURNS: TEXT SQL fragment for ORDER BY
 *
 * NOTE: This is a helper for code readability; it returns SQL text that
 *       should be used with EXECUTE in PL/pgSQL functions.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_order_by_clause(
    _direction hafbe_backend.sort_direction,
    _column    TEXT DEFAULT 'date'
)
RETURNS TEXT
LANGUAGE 'sql' STABLE
AS
$$
  SELECT format(
    'ORDER BY
      (CASE WHEN %L = ''desc'' THEN %I ELSE NULL END) DESC,
      (CASE WHEN %L = ''asc''  THEN %I ELSE NULL END) ASC',
    _direction, _column, _direction, _column
  );
$$;

/*
 * apply_period_window: Applies pagination window to a time-series result.
 *
 * Unified wrapper around OFFSET/LIMIT that uses the period_list_context's
 * list_context for offset and page_size values.
 *
 * PARAMETERS:
 *   _ctx - period_list_context containing pagination info
 *
 * RETURNS: TEXT SQL fragment for OFFSET/LIMIT
 */
CREATE OR REPLACE FUNCTION hafbe_backend.apply_period_window(
    _ctx hafbe_backend.period_list_context
)
RETURNS TEXT
LANGUAGE 'sql' STABLE
AS
$$
  SELECT format('OFFSET %L LIMIT %L', _ctx.list.offset_val, _ctx.list.page_size);
$$;

RESET ROLE;

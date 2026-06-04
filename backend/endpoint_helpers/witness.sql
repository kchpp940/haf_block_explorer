-- =============================================================================
-- Witness Helper Functions
-- =============================================================================
-- Functions for retrieving witness information including voters, vote history,
-- witness lists, and statistics. Supports flexible sorting and pagination.
-- =============================================================================

SET ROLE hafbe_owner;

-- =============================================================================
-- SECTION 1: Witness Voter Functions
-- =============================================================================

/*
 * get_witness_voters: Gets paginated list of accounts voting for a witness.
 *
 * Returns voter information including their vesting power breakdown
 * (account vests vs proxied vests).
 *
 * PARAMETERS:
 *   witness        - Witness account ID to get voters for
 *   filter_account - Optional: filter to specific voter (for search)
 *   page           - Page number (1-based)
 *   page-size      - Number of voters per page
 *   sort           - Sort field: 'vests', 'account_vests', 'proxied_vests', 'voter', 'timestamp'
 *   direction      - Sort direction: 'asc' or 'desc'
 *
 * RETURNS: Set of witness_voter records with voter details
 *
 * NOTE: Uses force_custom_plan due to dynamic parameter values that would
 * cause suboptimal generic plans.
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_witness_voters;
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness_voters(
    "witness"        INT,
    "filter_account" INT,
    "page"           INT,
    "page-size"      INT,
    "sort"           hafbe_backend.order_by_votes,
    "direction"      hafbe_backend.sort_direction
)
RETURNS SETOF hafbe_backend.witness_voter
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
AS
$$
DECLARE
  __offset INT := ((("page" - 1) * "page-size"));
BEGIN
  RETURN QUERY (
    /*
     * =========================================================================
     * CTE: limited_set
     * =========================================================================
     * WHY MATERIALIZED: Complex multi-way sort with joins, pagination applied.
     *
     * PURPOSE: Fetch voters with their vesting stats, sorted and paginated.
     *
     * JOINS:
     *   - current_witness_votes_view: Active votes for the witness
     *   - account_vest_stats_cache: Pre-calculated vest breakdowns
     *   - blocks_view: Vote timestamp from block
     *   - accounts_view: Voter account name
     *
     * DYNAMIC SORT:
     *   Uses CASE expressions to enable sorting by different columns.
     *   Each sort field has ASC and DESC variants. Only one CASE matches
     *   per row; others return NULL and are ignored.
     */
    WITH limited_set AS MATERIALIZED (
      SELECT
        av.name,
        avs.vests,
        avs.account_vests,
        avs.proxied_vests,
        bv.created_at
      FROM hafbe_backend.current_witness_votes_view cwv
      JOIN hafbe_app.account_vest_stats_cache avs ON avs.account_id = cwv.voter_id
      JOIN hive.blocks_view bv                    ON bv.num = cwv.source_op_block
      JOIN hive.accounts_view av                  ON av.id = cwv.voter_id
      WHERE
        cwv.witness_id = "witness" AND
        ("filter_account" IS NULL OR cwv.voter_id = "filter_account")
      ORDER BY
        -- Sort by total vests (account + proxied)
        (CASE WHEN "direction" = 'desc' AND "sort" = 'vests'          THEN avs.vests           ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'vests'          THEN avs.vests           ELSE NULL END) ASC,
        -- Sort by account's own vests only
        (CASE WHEN "direction" = 'desc' AND "sort" = 'account_vests'  THEN avs.account_vests   ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'account_vests'  THEN avs.account_vests   ELSE NULL END) ASC,
        -- Sort by vests received via proxy
        (CASE WHEN "direction" = 'desc' AND "sort" = 'proxied_vests'  THEN avs.proxied_vests   ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'proxied_vests'  THEN avs.proxied_vests   ELSE NULL END) ASC,
        -- Sort by voter name alphabetically
        (CASE WHEN "direction" = 'desc' AND "sort" = 'voter'          THEN av.name             ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'voter'          THEN av.name             ELSE NULL END) ASC,
        -- Sort by vote timestamp (using block number as proxy)
        (CASE WHEN "direction" = 'desc' AND "sort" = 'timestamp'      THEN cwv.source_op_block ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'timestamp'      THEN cwv.source_op_block ELSE NULL END) ASC,
        -- Tiebreaker: voter_id for stable ordering
        (CASE WHEN "direction" = 'desc'                               THEN cwv.voter_id        ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'                                THEN cwv.voter_id        ELSE NULL END) ASC
      OFFSET __offset
      LIMIT "page-size"
    )
    -- Cast numeric values to TEXT to avoid JSON compression issues with large numbers
    SELECT
      ls.name::TEXT,
      ls.vests::TEXT,
      ls.account_vests::TEXT,
      ls.proxied_vests::TEXT,
      ls.created_at
    FROM limited_set ls
  );
END
$$;

/*
 * get_witness_votes_history: Gets historical voting records for a witness.
 *
 * Returns vote history including both approve and unapprove actions.
 * Handles cases where voters no longer have current stats by falling
 * back to expired voter stats.
 *
 * PARAMETERS:
 *   witness        - Witness account ID
 *   filter_account - Optional: filter to specific voter
 *   page           - Page number (1-based)
 *   page-size      - Number of records per page
 *   direction      - Sort direction: 'asc' or 'desc'
 *   from-block     - Optional: starting block filter
 *   to-block       - Optional: ending block filter
 *
 * RETURNS: Set of witness_votes_history_record with vote details
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_witness_votes_history;
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness_votes_history(
    "witness"        INT,
    "filter_account" INT,
    "page"           INT,
    "page-size"      INT,
    "direction"      hafbe_backend.sort_direction,
    "from-block"     INT,
    "to-block"       INT
)
RETURNS SETOF hafbe_backend.witness_votes_history_record
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
AS
$$
DECLARE
  __offset INT := ((("page" - 1) * "page-size"));
BEGIN
  RETURN QUERY (
    /*
     * =========================================================================
     * CTE: limited_set
     * =========================================================================
     * WHY MATERIALIZED: Complex filters and joins, pagination applied.
     *
     * PURPOSE: Fetch vote history with vest stats at time of vote.
     *
     * NOTE: Uses LEFT JOIN to account_vest_stats_cache because voters who
     * removed their vote won't have current stats. These will be filled
     * from expired_voter_stats_view in later CTEs.
     */
    WITH limited_set AS MATERIALIZED (
      SELECT
        av.name,
        cwv.voter_id,
        cwv.approve,
        avs.vests,
        avs.account_vests,
        avs.proxied_vests,
        cwv.source_op_block,
        bv.created_at
      FROM hafbe_backend.witness_votes_history_view cwv
      -- LEFT JOIN: voter may no longer be active, stats may be NULL
      LEFT JOIN hafbe_app.account_vest_stats_cache avs ON avs.account_id = cwv.voter_id
      JOIN hive.blocks_view bv                         ON bv.num = cwv.source_op_block
      JOIN hive.accounts_view av                       ON av.id = cwv.voter_id
      WHERE
        cwv.witness_id = "witness" AND
        ("filter_account" IS NULL OR cwv.voter_id = "filter_account") AND
        ("from-block" IS NULL     OR cwv.source_op_block >= "from-block") AND
        ("to-block" IS NULL       OR cwv.source_op_block <= "to-block")
      ORDER BY
        (CASE WHEN "direction" = 'desc' THEN cwv.source_op_block ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  THEN cwv.source_op_block ELSE NULL END) ASC,
        (CASE WHEN "direction" = 'desc' THEN cwv.voter_id        ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  THEN cwv.voter_id        ELSE NULL END) ASC
      OFFSET __offset
      LIMIT "page-size"
    ),

    /*
     * =========================================================================
     * CTE: empty_results
     * =========================================================================
     * PURPOSE: For voters without current stats, fetch from expired stats.
     *
     * Expired voter stats are preserved for historical accuracy even after
     * a voter removes their vote.
     */
    empty_results AS (
      SELECT
        ls.name,
        ls.voter_id,
        ls.approve,
        evs.vests,
        evs.account_vests,
        evs.proxied_vests,
        ls.source_op_block,
        ls.created_at
      FROM limited_set ls
      JOIN hafbe_backend.expired_voter_stats_view evs ON evs.account_id = ls.voter_id
      WHERE ls.vests IS NULL
    ),

    /*
     * =========================================================================
     * CTE: not_empty_results
     * =========================================================================
     * PURPOSE: Pass through records that already have stats.
     */
    not_empty_results AS (
      SELECT
        ls.name,
        ls.voter_id,
        ls.approve,
        ls.vests,
        ls.account_vests,
        ls.proxied_vests,
        ls.source_op_block,
        ls.created_at
      FROM limited_set ls
      WHERE ls.vests IS NOT NULL
    ),

    /*
     * =========================================================================
     * CTE: union_results
     * =========================================================================
     * PURPOSE: Combine records with and without current stats.
     */
    union_results AS (
      SELECT * FROM empty_results
      UNION ALL
      SELECT * FROM not_empty_results
    )

    SELECT
      ur.name::TEXT,
      ur.approve,
      ur.vests::TEXT,
      ur.account_vests::TEXT,
      ur.proxied_vests::TEXT,
      ur.created_at
    FROM union_results ur
    -- Re-apply sort after UNION
    ORDER BY
      (CASE WHEN "direction" = 'desc' THEN ur.source_op_block ELSE NULL END) DESC,
      (CASE WHEN "direction" = 'asc'  THEN ur.source_op_block ELSE NULL END) ASC,
      (CASE WHEN "direction" = 'desc' THEN ur.voter_id        ELSE NULL END) DESC,
      (CASE WHEN "direction" = 'asc'  THEN ur.voter_id        ELSE NULL END) ASC
  );
END
$$;

-- =============================================================================
-- SECTION 2: Witness List Functions
-- =============================================================================

/*
 * get_witnesses: Gets paginated list of all witnesses with statistics.
 *
 * Returns comprehensive witness data including votes, daily changes,
 * price feed, and configuration parameters.
 *
 * PARAMETERS:
 *   page      - Page number (1-based)
 *   page-size - Number of witnesses per page
 *   sort      - Sort field (see order_by_witness enum for options)
 *   direction - Sort direction: 'asc' or 'desc'
 *
 * RETURNS: Set of witness records with all statistics
 *
 * DATA SOURCES:
 *   - current_witnesses: Core witness configuration
 *   - witness_rank_cache: Pre-calculated rank
 *   - witness_votes_cache: Total votes and voter count
 *   - witness_votes_change_cache: Daily vote changes
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_witnesses;
CREATE OR REPLACE FUNCTION hafbe_backend.get_witnesses(
    "page"      INT,
    "page-size" INT,
    "sort"      hafbe_backend.order_by_witness,
    "direction" hafbe_backend.sort_direction
)
RETURNS SETOF hafbe_backend.witness
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
AS
$$
DECLARE
  __offset INT := ((("page" - 1) * "page-size"));
BEGIN
  RETURN QUERY (
    WITH limited_set AS (
      SELECT
        cw.witness_id,
        av.name,
        a.rank,
        -- COALESCE provides defaults for witnesses without data
        COALESCE(cw.url, '')                                AS url,
        COALESCE(cw.price_feed, '0.000'::NUMERIC)           AS price_feed,
        COALESCE(cw.bias, 0)                                AS bias,
        COALESCE(cw.feed_updated_at, '1970-01-01 00:00:00'::TIMESTAMP) AS feed_updated_at,
        COALESCE(cw.block_size, 0)                          AS block_size,
        COALESCE(cw.signing_key, '')                        AS signing_key,
        COALESCE(cw.version, '0.0.0')                       AS version,
        COALESCE(cw.missed_blocks, 0)                       AS missed_blocks,
        COALESCE(b.votes, 0)                                AS votes,
        COALESCE(b.voters_num, 0)                           AS voters_num,
        COALESCE(c.votes_daily_change, 0)                   AS votes_daily_change,
        COALESCE(c.voters_num_daily_change, 0)              AS voters_num_daily_change,
        COALESCE(cw.hbd_interest_rate, 0)                   AS hbd_interest_rate,
        COALESCE(cw.last_created_block_num, 0)              AS last_created_block_num,
        COALESCE(cw.account_creation_fee, 0)                AS account_creation_fee
      FROM hafbe_app.current_witnesses cw
      JOIN hive.accounts_view av                       ON av.id = cw.witness_id
      JOIN hafbe_app.witness_rank_cache a              ON a.witness_id = cw.witness_id
      LEFT JOIN hafbe_app.witness_votes_cache b        ON b.witness_id = cw.witness_id
      LEFT JOIN hafbe_app.witness_votes_change_cache c ON c.witness_id = cw.witness_id
      ORDER BY
        -- Sort by witness name
        (CASE WHEN "direction" = 'desc' AND "sort" = 'witness'                 THEN av.name                                                        ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'witness'                 THEN av.name                                                        ELSE NULL END) ASC,
        -- Sort by rank
        (CASE WHEN "direction" = 'desc' AND "sort" = 'rank'                    THEN a.rank                                                         ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'rank'                    THEN a.rank                                                         ELSE NULL END) ASC,
        -- Sort by URL
        (CASE WHEN "direction" = 'desc' AND "sort" = 'url'                     THEN COALESCE(cw.url, '')                                           ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'url'                     THEN COALESCE(cw.url, '')                                           ELSE NULL END) ASC,
        -- Sort by votes (uses rank for efficiency - rank is derived from votes)
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'votes'                   THEN a.rank                                                         ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'desc' AND "sort" = 'votes'                   THEN a.rank                                                         ELSE NULL END) ASC,
        -- Sort by daily vote change
        (CASE WHEN "direction" = 'desc' AND "sort" = 'votes_daily_change'      THEN COALESCE(c.votes_daily_change, 0)                              ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'votes_daily_change'      THEN COALESCE(c.votes_daily_change, 0)                              ELSE NULL END) ASC,
        -- Sort by number of voters
        (CASE WHEN "direction" = 'desc' AND "sort" = 'voters_num'              THEN COALESCE(b.voters_num, 0)                                      ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'voters_num'              THEN COALESCE(b.voters_num, 0)                                      ELSE NULL END) ASC,
        -- Sort by daily voter count change
        (CASE WHEN "direction" = 'desc' AND "sort" = 'voters_num_daily_change' THEN COALESCE(c.voters_num_daily_change, 0)                         ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'voters_num_daily_change' THEN COALESCE(c.voters_num_daily_change, 0)                         ELSE NULL END) ASC,
        -- Sort by price feed
        (CASE WHEN "direction" = 'desc' AND "sort" = 'price_feed'              THEN COALESCE(cw.price_feed, '0.000'::NUMERIC)                      ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'price_feed'              THEN COALESCE(cw.price_feed, '0.000'::NUMERIC)                      ELSE NULL END) ASC,
        -- Sort by feed bias
        (CASE WHEN "direction" = 'desc' AND "sort" = 'bias'                    THEN COALESCE(cw.bias, 0)                                           ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'bias'                    THEN COALESCE(cw.bias, 0)                                           ELSE NULL END) ASC,
        -- Sort by preferred block size
        (CASE WHEN "direction" = 'desc' AND "sort" = 'block_size'              THEN COALESCE(cw.block_size, 0)                                     ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'block_size'              THEN COALESCE(cw.block_size, 0)                                     ELSE NULL END) ASC,
        -- Sort by signing key
        (CASE WHEN "direction" = 'desc' AND "sort" = 'signing_key'             THEN COALESCE(cw.signing_key, '')                                   ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'signing_key'             THEN COALESCE(cw.signing_key, '')                                   ELSE NULL END) ASC,
        -- Sort by node version
        (CASE WHEN "direction" = 'desc' AND "sort" = 'version'                 THEN COALESCE(cw.version, '0.0.0')                                  ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'version'                 THEN COALESCE(cw.version, '0.0.0')                                  ELSE NULL END) ASC,
        -- Sort by feed update time
        (CASE WHEN "direction" = 'desc' AND "sort" = 'feed_updated_at'         THEN COALESCE(cw.feed_updated_at, '1970-01-01 00:00:00'::TIMESTAMP) ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'  AND "sort" = 'feed_updated_at'         THEN COALESCE(cw.feed_updated_at, '1970-01-01 00:00:00'::TIMESTAMP) ELSE NULL END) ASC,
        -- Tiebreaker: witness_id for stable ordering
        (CASE WHEN "direction" = 'desc'                                        THEN cw.witness_id                                                  ELSE NULL END) DESC,
        (CASE WHEN "direction" = 'asc'                                         THEN cw.witness_id                                                  ELSE NULL END) ASC
      OFFSET __offset
      LIMIT "page-size"
    )
    SELECT
      ls.name::TEXT,
      ls.rank,
      ls.url,
      ls.votes::TEXT,
      ls.votes_daily_change::TEXT,
      ls.voters_num,
      ls.voters_num_daily_change,
      ls.price_feed,
      ls.bias,
      ls.feed_updated_at,
      ls.block_size,
      ls.signing_key,
      ls.version,
      ls.missed_blocks,
      ls.hbd_interest_rate,
      ls.last_created_block_num,
      ls.account_creation_fee
    FROM limited_set ls
  );
END
$$;

/*
 * get_witness: Gets detailed information for a single witness.
 *
 * PARAMETERS:
 *   _witness_id - Witness account ID
 *
 * RETURNS: Single witness record with all statistics
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_witness;
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness(
    _witness_id INT
)
RETURNS hafbe_backend.witness
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
AS
$$
BEGIN
  RETURN (
    WITH limited_set AS (
      SELECT
        cw.witness_id,
        -- Use subquery for single account lookup (see refactoring notes)
        (SELECT av.name FROM hive.accounts_view av WHERE av.id = _witness_id)::TEXT AS witness,
        COALESCE(cw.url, '')                                AS url,
        COALESCE(cw.price_feed, '0.000'::NUMERIC)           AS price_feed,
        COALESCE(cw.bias, 0)                                AS bias,
        COALESCE(cw.feed_updated_at, '1970-01-01 00:00:00'::TIMESTAMP) AS feed_updated_at,
        COALESCE(cw.block_size, 0)                          AS block_size,
        COALESCE(cw.signing_key, '')                        AS signing_key,
        COALESCE(cw.version, '0.0.0')                       AS version,
        COALESCE(cw.missed_blocks, 0)                       AS missed_blocks,
        COALESCE(cw.hbd_interest_rate, 0)                   AS hbd_interest_rate,
        COALESCE(cw.last_created_block_num, 0)              AS last_created_block_num,
        COALESCE(cw.account_creation_fee, 0)                AS account_creation_fee
      FROM hafbe_app.current_witnesses cw
      WHERE cw.witness_id = _witness_id
    )
    SELECT ROW(
      ls.witness,
      a.rank,
      ls.url,
      COALESCE(all_votes.votes::TEXT, '0'),
      COALESCE(wvcc.votes_daily_change::TEXT, '0'),
      COALESCE(all_votes.voters_num, 0),
      COALESCE(wvcc.voters_num_daily_change, 0),
      ls.price_feed,
      ls.bias,
      ls.feed_updated_at,
      ls.block_size,
      ls.signing_key,
      ls.version,
      ls.missed_blocks,
      ls.hbd_interest_rate,
      ls.last_created_block_num,
      ls.account_creation_fee
    )
    FROM limited_set ls
    JOIN hafbe_app.witness_rank_cache a                 ON a.witness_id = ls.witness_id
    LEFT JOIN hafbe_app.witness_votes_cache all_votes   ON all_votes.witness_id = ls.witness_id
    LEFT JOIN hafbe_app.witness_votes_change_cache wvcc ON wvcc.witness_id = ls.witness_id
  );
END
$$;

-- =============================================================================
-- SECTION 3: Count Functions
-- =============================================================================

/*
 * get_witness_voters_count: Counts total voters for a witness.
 *
 * PARAMETERS:
 *   _witness_id        - Witness account ID
 *   _filter_account_id - Optional: filter to specific voter
 *
 * RETURNS: Count of voters matching criteria
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness_voters_count(
    _witness_id        INT,
    _filter_account_id INT
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN COUNT(*)
  FROM hafbe_backend.current_witness_votes_view
  WHERE
    witness_id = _witness_id AND
    (_filter_account_id IS NULL OR voter_id = _filter_account_id);
END
$$;

/*
 * get_witness_votes_history_count: Counts historical vote records for a witness.
 *
 * PARAMETERS:
 *   _witness_id        - Witness account ID
 *   _filter_account_id - Optional: filter to specific voter
 *   _block_range       - Optional: block range filter
 *
 * RETURNS: Count of vote history records matching criteria
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness_votes_history_count(
    _witness_id        INT,
    _filter_account_id INT,
    _block_range       hive.blocks_range
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN COUNT(*)
  FROM hafbe_backend.witness_votes_history_view
  WHERE
    witness_id = _witness_id AND
    (_block_range.first_block IS NULL OR source_op_block >= _block_range.first_block) AND
    (_block_range.last_block IS NULL  OR source_op_block <= _block_range.last_block) AND
    (_filter_account_id IS NULL       OR voter_id = _filter_account_id);
END
$$;

/*
 * get_witnesses_count: Counts total number of witnesses.
 *
 * RETURNS: Total count of registered witnesses
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_witnesses_count()
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN COUNT(*)
  FROM hafbe_app.current_witnesses;
END
$$;

-- =============================================================================
-- SECTION 4: Vote Timeline Aggregation
-- =============================================================================

/*
 * get_witness_votes_timeline_count: Count total time periods for witness vote timeline.
 *
 * Used by endpoint wrapper to calculate total_pages. Counts the number of
 * time buckets that would be returned by get_witness_votes_timeline.
 *
 * PARAMETERS:
 *   _witness_id  - Witness account ID
 *   _granularity - Time granularity: 'daily', 'monthly', or 'yearly'
 *   _from_block  - Start block number
 *   _to_block    - End block number
 *
 * RETURNS: Total count of time periods
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_witness_votes_timeline_count;
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness_votes_timeline_count(
    _witness_id  INT,
    _granularity hafbe_backend.granularity,
    _from_block  INT,
    _to_block    INT
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  _ctx hafbe_backend.period_context := hafbe_backend.resolve_period_context(_granularity, _from_block, _to_block);
BEGIN
  RETURN (
    SELECT COUNT(*)::INT
    FROM hafbe_backend.generate_time_buckets(_ctx)
  );
END
$$;

/*
 * get_witness_votes_timeline: Aggregate witness vote changes by time period.
 *
 * Generates a time-series of vote changes for a witness at the requested
 * granularity (daily, monthly, yearly). Uses the unified statistics_period
 * helpers for time-bucket generation, gap filling, date adjustment,
 * pagination, and sort direction.
 *
 * PARAMETERS:
 *   _witness_id  - Witness account ID to get timeline for
 *   _ctx         - Unified period+list+direction context (from resolve_period_list_context)
 *
 * RETURNS: Set of witness_votes_timeline_record records (paginated)
 *
 * AGGREGATION LOGIC:
 *   - votes_added: Count of approve=TRUE vote operations in the period
 *   - votes_removed: Count of approve=FALSE vote operations in the period
 *   - net_votes_change: votes_added - votes_removed
 *   - vests_added: Sum of vests for approve=TRUE operations
 *   - vests_removed: Sum of vests for approve=FALSE operations
 *   - net_vests_change: vests_added - vests_removed
 *
 * UNIFIED PATTERN (shared with transaction and proposal stats):
 *   1. resolve_period_list_context() - parse all params at once
 *   2. generate_time_buckets() - complete period coverage
 *   3. LEFT JOIN with actual data - gaps become NULL
 *   4. LATERAL JOIN find_nearest_block_before() - fill missing last_block_num
 *   5. adjust_to_period_end() - date normalization
 *   6. CASE-WHEN ORDER BY - unified sort direction
 *   7. OFFSET/LIMIT - pagination window
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_witness_votes_timeline;
CREATE OR REPLACE FUNCTION hafbe_backend.get_witness_votes_timeline(
    _witness_id INT,
    _ctx        hafbe_backend.period_list_context
)
RETURNS SETOF hafbe_backend.witness_votes_timeline_record
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN QUERY (
    WITH date_series AS (
      SELECT hafbe_backend.generate_time_buckets(_ctx.period) AS period
    ),
    vote_changes AS MATERIALIZED (
      SELECT
        DATE_TRUNC(_ctx.period.granularity_text, bv.created_at)::TIMESTAMP AS period,
        COUNT(CASE WHEN wvh.approve THEN 1 END)::INT                AS votes_added,
        COUNT(CASE WHEN NOT wvh.approve THEN 1 END)::INT            AS votes_removed,
        SUM(CASE WHEN wvh.approve THEN COALESCE(avs.vests, 0) ELSE 0 END)::BIGINT  AS vests_added,
        SUM(CASE WHEN NOT wvh.approve THEN COALESCE(avs.vests, 0) ELSE 0 END)::BIGINT AS vests_removed,
        MAX(wvh.source_op_block)::INT                                AS last_block_num
      FROM hafbe_backend.witness_votes_history_view wvh
      JOIN hive.blocks_view bv ON bv.num = wvh.source_op_block
      LEFT JOIN hafbe_backend.expired_voter_stats_view avs ON avs.account_id = wvh.voter_id
      WHERE wvh.witness_id = _witness_id
        AND bv.created_at BETWEEN _ctx.period.from_timestamp AND (_ctx.period.to_timestamp + _ctx.period.one_period)
      GROUP BY DATE_TRUNC(_ctx.period.granularity_text, bv.created_at)
    ),
    timeline_records AS (
      SELECT
        ds.period,
        COALESCE(vc.votes_added, 0)     AS votes_added,
        COALESCE(vc.votes_removed, 0)   AS votes_removed,
        COALESCE(vc.votes_added, 0) - COALESCE(vc.votes_removed, 0) AS net_votes_change,
        COALESCE(vc.vests_added, 0)     AS vests_added,
        COALESCE(vc.vests_removed, 0)   AS vests_removed,
        COALESCE(vc.vests_added, 0) - COALESCE(vc.vests_removed, 0) AS net_vests_change,
        vc.last_block_num               AS last_block_num
      FROM date_series ds
      LEFT JOIN vote_changes vc ON ds.period = vc.period
    ),
    join_missing_block AS (
      SELECT
        tr.period,
        tr.votes_added,
        tr.votes_removed,
        tr.net_votes_change,
        tr.vests_added,
        tr.vests_removed,
        tr.net_vests_change,
        COALESCE(tr.last_block_num, jl.last_block_num) AS last_block_num
      FROM timeline_records tr
      LEFT JOIN LATERAL (
        SELECT hafbe_backend.find_nearest_block_before(tr.period + _ctx.period.one_period) AS last_block_num
      ) jl ON tr.last_block_num IS NULL
    )
    SELECT
      hafbe_backend.adjust_to_period_end(jmb.period, _ctx.period.one_period) AS date,
      jmb.votes_added,
      jmb.votes_removed,
      jmb.net_votes_change,
      jmb.vests_added::TEXT,
      jmb.vests_removed::TEXT,
      jmb.net_vests_change::TEXT,
      jmb.last_block_num
    FROM join_missing_block jmb
    ORDER BY
      (CASE WHEN _ctx.direction = 'desc' THEN jmb.period ELSE NULL END) DESC,
      (CASE WHEN _ctx.direction = 'asc'  THEN jmb.period ELSE NULL END) ASC
    OFFSET _ctx.list.offset_val
    LIMIT _ctx.list.page_size
  );
END
$$;

RESET ROLE;

-- =============================================================================
-- Proposal Helper Functions
-- =============================================================================
-- Functions for retrieving proposal-related information including vote history.
-- Supports pagination, voter filtering, and block range filtering.
-- =============================================================================

SET ROLE hafbe_owner;

-- =============================================================================
-- SECTION 1: Proposal Vote History Functions
-- =============================================================================

/*
 * get_proposal_votes_history: Gets historical voting records for a proposal.
 *
 * Returns vote history including both approve and unapprove actions against a
 * given proposal. Unlike witness votes, proposal vote history does not carry
 * vest/voting-power stats — it is a pure (voter, approve, timestamp) stream.
 *
 * PARAMETERS:
 *   proposal_id    - Proposal id to get vote history for
 *   filter_account - Optional: filter to a specific voter account id
 *   page           - Page number (1-based)
 *   page-size      - Number of records per page
 *   direction      - Sort direction: 'asc' or 'desc' (by block)
 *   from-block     - Optional: lower block bound (inclusive)
 *   to-block       - Optional: upper block bound (inclusive)
 *
 * RETURNS: Set of proposal_votes_history_record with voter name, approve flag
 *          and block timestamp.
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_proposal_votes_history;
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposal_votes_history(
    _proposal_id     INT,
    _filter_account  INT,
    _page            INT,
    _page_size       INT,
    _direction       hafbe_backend.sort_direction,
    _from_block      INT,
    _to_block        INT
)
RETURNS SETOF hafbe_backend.proposal_votes_history_record
LANGUAGE 'plpgsql' STABLE
SET plan_cache_mode = force_custom_plan
AS
$$
DECLARE
  __offset INT := ((_page - 1) * _page_size);
BEGIN
  RETURN QUERY (
    WITH limited_set AS MATERIALIZED (
      SELECT
        av.name,
        pvh.voter_id,
        pvh.approve,
        pvh.source_op_block,
        bv.created_at
      FROM hafbe_backend.proposal_votes_history_view pvh
      JOIN hive.blocks_view bv   ON bv.num = pvh.source_op_block
      JOIN hive.accounts_view av ON av.id = pvh.voter_id
      WHERE
        pvh.proposal_id = _proposal_id AND
        (_filter_account IS NULL OR pvh.voter_id = _filter_account) AND
        (_from_block IS NULL     OR pvh.source_op_block >= _from_block) AND
        (_to_block IS NULL       OR pvh.source_op_block <= _to_block)
      ORDER BY
        (CASE WHEN _direction = 'desc' THEN pvh.source_op_block ELSE NULL END) DESC,
        (CASE WHEN _direction = 'asc'  THEN pvh.source_op_block ELSE NULL END) ASC,
        (CASE WHEN _direction = 'desc' THEN pvh.voter_id        ELSE NULL END) DESC,
        (CASE WHEN _direction = 'asc'  THEN pvh.voter_id        ELSE NULL END) ASC
      OFFSET __offset
      LIMIT _page_size
    )
    SELECT
      ls.name::TEXT,
      ls.approve,
      ls.created_at
    FROM limited_set ls
  );
END
$$;

-- =============================================================================
-- SECTION 2: Count Functions
-- =============================================================================

/*
 * get_proposal_votes_history_count: Counts historical vote records for a proposal.
 *
 * PARAMETERS:
 *   _proposal_id       - Proposal id
 *   _filter_account_id - Optional: filter to a specific voter account id
 *   _block_range       - Optional: block range filter
 *
 * RETURNS: Count of vote history records matching criteria
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposal_votes_history_count(
    _proposal_id       INT,
    _filter_account_id INT,
    _block_range       hive.blocks_range
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN COUNT(*)
  FROM hafbe_backend.proposal_votes_history_view
  WHERE
    proposal_id = _proposal_id AND
    (_block_range.first_block IS NULL OR source_op_block >= _block_range.first_block) AND
    (_block_range.last_block IS NULL  OR source_op_block <= _block_range.last_block) AND
    (_filter_account_id IS NULL       OR voter_id = _filter_account_id);
END
$$;

-- =============================================================================
-- SECTION 3: Proposal Listing & Active Votes
-- =============================================================================

/*
 * proposal_status_matches: Single source of truth for proposal status filtering.
 *
 * Mirrors hived's `proposal_status` enum semantics:
 *   - active:   now is within [start_date, end_date]
 *   - inactive: now is before start_date
 *   - expired:  now is after end_date
 *   - votable:  active OR inactive (i.e. now <= end_date)
 *   - all:      any status, but still excluding `removed = TRUE`
 *
 * Removed proposals are NEVER returned by any status filter; they remain in
 * the table only to keep historical joins (votes/payments) intact.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.proposal_status_matches(
    _status     hafbe_backend.proposal_status,
    _start_date TIMESTAMP,
    _end_date   TIMESTAMP,
    _removed    BOOLEAN,
    _now        TIMESTAMP
)
RETURNS BOOLEAN
LANGUAGE 'sql' IMMUTABLE
AS $$
  SELECT NOT _removed AND CASE _status
    WHEN 'all'      THEN TRUE
    WHEN 'active'   THEN _now >= _start_date AND _now <= _end_date
    WHEN 'inactive' THEN _now <  _start_date
    WHEN 'expired'  THEN _now >  _end_date
    WHEN 'votable'  THEN _now <= _end_date
  END;
$$;

/*
 * get_proposals_count: Count proposals matching the status and optional filters.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposals_count(
    _status       hafbe_backend.proposal_status,
    _creator_id   INT   DEFAULT NULL,
    _proposal_ids INT[] DEFAULT NULL,
    _voter_id     INT   DEFAULT NULL,
    _search       TEXT  DEFAULT NULL
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS $$
DECLARE
  _now TIMESTAMP := (SELECT created_at FROM hive.blocks_view WHERE num = hafbe_backend.get_hafbe_head_block());
BEGIN
  RETURN COUNT(*)
  FROM hafbe_app.current_proposals cp
  WHERE hafbe_backend.proposal_status_matches(_status, cp.start_date, cp.end_date, cp.removed, _now)
    AND (_creator_id   IS NULL OR cp.creator_id = _creator_id)
    AND (_proposal_ids IS NULL OR cp.proposal_id = ANY(_proposal_ids))
    AND (_search       IS NULL OR cp.subject = _search)
    AND (_voter_id     IS NULL OR EXISTS (
          SELECT 1 FROM hafbe_app.current_proposal_votes cpv
          WHERE cpv.proposal_id = cp.proposal_id AND cpv.voter_id = _voter_id
        ));
END $$;

/*
 * get_proposals: Paginated proposal listing.
 *
 * Pagination is applied BEFORE name/cache/payment joins (limited_set CTE),
 * mirroring the witness/blocksearch pattern: cut the working set first,
 * then enrich.
 *
 * Sort backing:
 *   - by_creator    -> join accounts_view, sort on creator name
 *   - by_start_date -> current_proposals.start_date
 *   - by_end_date   -> current_proposals.end_date
 *   - by_total_votes-> proposal_vote_stats_cache.total_votes (NULL=0 via LEFT JOIN)
 *
 * paid_amount is a running total column on current_proposals, incremented by
 * process_proposal_pay_op on each DHF payment. proposal_payments stays as an
 * audit ledger but is no longer aggregated per request.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposals(
    _status       hafbe_backend.proposal_status,
    _page         INT,
    _page_size    INT,
    _sort         hafbe_backend.order_by_proposal,
    _direction    hafbe_backend.sort_direction,
    _creator_id   INT   DEFAULT NULL,
    _proposal_ids INT[] DEFAULT NULL,
    _voter_id     INT   DEFAULT NULL,
    _search       TEXT  DEFAULT NULL
)
RETURNS SETOF hafbe_backend.proposal
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
-- Dynamic ORDER BY CASE expressions need a per-call plan; the generic
-- plan PostgreSQL caches after 5 invocations picks an arbitrary index
-- regardless of _sort/_direction. Matches the pattern in
-- get_proposal_votes_history.
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
  __offset INT       := ((_page - 1) * _page_size);
  _now     TIMESTAMP := (SELECT created_at FROM hive.blocks_view WHERE num = hafbe_backend.get_hafbe_head_block());
BEGIN
  RETURN QUERY (
    WITH filtered AS (
      SELECT cp.proposal_id, cp.creator_id, cp.start_date, cp.end_date
      FROM hafbe_app.current_proposals cp
      WHERE hafbe_backend.proposal_status_matches(_status, cp.start_date, cp.end_date, cp.removed, _now)
        AND (_creator_id   IS NULL OR cp.creator_id = _creator_id)
        AND (_proposal_ids IS NULL OR cp.proposal_id = ANY(_proposal_ids))
        AND (_search       IS NULL OR cp.subject = _search)
        AND (_voter_id     IS NULL OR EXISTS (
              SELECT 1 FROM hafbe_app.current_proposal_votes cpv
              WHERE cpv.proposal_id = cp.proposal_id AND cpv.voter_id = _voter_id
            ))
    ),
    creator_keyed AS (
      SELECT f.proposal_id, av.name AS creator_name, f.start_date, f.end_date
      FROM filtered f
      JOIN hafbe_app.accounts_view av ON av.id = f.creator_id
    ),
    limited_set AS MATERIALIZED (
      SELECT ck.proposal_id
      FROM creator_keyed ck
      LEFT JOIN hafbe_app.proposal_vote_stats_cache vsc ON vsc.proposal_id = ck.proposal_id
      ORDER BY
        (CASE WHEN _sort = 'by_creator'     AND _direction = 'asc'  THEN ck.creator_name             END) ASC,
        (CASE WHEN _sort = 'by_creator'     AND _direction = 'desc' THEN ck.creator_name             END) DESC,
        (CASE WHEN _sort = 'by_start_date'  AND _direction = 'asc'  THEN ck.start_date               END) ASC,
        (CASE WHEN _sort = 'by_start_date'  AND _direction = 'desc' THEN ck.start_date               END) DESC,
        (CASE WHEN _sort = 'by_end_date'    AND _direction = 'asc'  THEN ck.end_date                 END) ASC,
        (CASE WHEN _sort = 'by_end_date'    AND _direction = 'desc' THEN ck.end_date                 END) DESC,
        (CASE WHEN _sort = 'by_total_votes' AND _direction = 'asc'  THEN COALESCE(vsc.total_votes,0) END) ASC,
        (CASE WHEN _sort = 'by_total_votes' AND _direction = 'desc' THEN COALESCE(vsc.total_votes,0) END) DESC,
        -- Deterministic tie-break that flips with _direction so pagination
        -- stays consistent across asc/desc traversals.
        (CASE WHEN _direction = 'asc'  THEN ck.proposal_id END) ASC,
        (CASE WHEN _direction = 'desc' THEN ck.proposal_id END) DESC
      OFFSET __offset
      LIMIT _page_size
    )
    SELECT
      cp.proposal_id                                                                   AS id,
      cp.proposal_id                                                                   AS proposal_id,
      cav.name::TEXT                                                                   AS creator,
      rav.name::TEXT                                                                   AS receiver,
      cp.start_date,
      cp.end_date,
      cp.daily_pay::TEXT                                                               AS daily_pay,
      cp.subject,
      cp.permlink,
      COALESCE(vsc.total_votes, 0)::TEXT                                               AS total_votes,
      COALESCE(vsc.voters_num, 0)                                                      AS voters_num,
      cp.paid_amount::TEXT                                                             AS paid_amount,
      (CASE
        WHEN _now > cp.end_date   THEN 'expired'
        WHEN _now < cp.start_date THEN 'inactive'
        ELSE                            'active'
      END)::TEXT                                                                       AS status
    FROM limited_set ls
    JOIN hafbe_app.current_proposals      cp  ON cp.proposal_id   = ls.proposal_id
    JOIN hafbe_app.accounts_view          cav ON cav.id           = cp.creator_id
    JOIN hafbe_app.accounts_view          rav ON rav.id           = cp.receiver_id
    LEFT JOIN hafbe_app.proposal_vote_stats_cache vsc ON vsc.proposal_id = cp.proposal_id
    ORDER BY
      (CASE WHEN _sort = 'by_creator'     AND _direction = 'asc'  THEN cav.name                    END) ASC,
      (CASE WHEN _sort = 'by_creator'     AND _direction = 'desc' THEN cav.name                    END) DESC,
      (CASE WHEN _sort = 'by_start_date'  AND _direction = 'asc'  THEN cp.start_date               END) ASC,
      (CASE WHEN _sort = 'by_start_date'  AND _direction = 'desc' THEN cp.start_date               END) DESC,
      (CASE WHEN _sort = 'by_end_date'    AND _direction = 'asc'  THEN cp.end_date                 END) ASC,
      (CASE WHEN _sort = 'by_end_date'    AND _direction = 'desc' THEN cp.end_date                 END) DESC,
      (CASE WHEN _sort = 'by_total_votes' AND _direction = 'asc'  THEN COALESCE(vsc.total_votes,0) END) ASC,
      (CASE WHEN _sort = 'by_total_votes' AND _direction = 'desc' THEN COALESCE(vsc.total_votes,0) END) DESC,
      (CASE WHEN _direction = 'asc'  THEN cp.proposal_id END) ASC,
      (CASE WHEN _direction = 'desc' THEN cp.proposal_id END) DESC
  );
END $$;

-- =============================================================================
-- SECTION 4: Proposal Votes Listing
-- =============================================================================

/*
 * get_proposal_votes_count: Count active proposal votes matching the status and optional filters.
 *
 * The status filter applies to the JOINED proposal, not the vote itself.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposal_votes_count(
    _status      hafbe_backend.proposal_status,
    _proposal_id INT DEFAULT NULL,
    _voter_id    INT DEFAULT NULL
)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS $$
DECLARE
  _now TIMESTAMP := (SELECT created_at FROM hive.blocks_view WHERE num = hafbe_backend.get_hafbe_head_block());
BEGIN
  RETURN COUNT(*)
  FROM hafbe_app.current_proposal_votes cpv
  JOIN hafbe_app.current_proposals      cp  ON cp.proposal_id = cpv.proposal_id
  WHERE hafbe_backend.proposal_status_matches(_status, cp.start_date, cp.end_date, cp.removed, _now)
    AND (_proposal_id IS NULL OR cpv.proposal_id = _proposal_id)
    AND (_voter_id    IS NULL OR cpv.voter_id    = _voter_id);
END $$;

/*
 * get_proposal_votes: Paginated current active proposal votes.
 *
 * Sort backing:
 *   - by_voter_proposal -> (voter_id, proposal_id)
 *   - by_proposal_voter -> (proposal_id, voter_id)
 *
 * voter_vests is reported as 0 for voters who currently have a governance
 * proxy set, matching how stake is accounted for in hived's proposal totals
 * (their stake counts through the proxy, not through this direct vote).
 *
 * Status filter applies to the joined proposal, not the vote.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposal_votes(
    _status      hafbe_backend.proposal_status,
    _page        INT,
    _page_size   INT,
    _sort        hafbe_backend.order_by_proposal_vote,
    _direction   hafbe_backend.sort_direction,
    _proposal_id INT DEFAULT NULL,
    _voter_id    INT DEFAULT NULL
)
RETURNS SETOF hafbe_backend.proposal_vote
LANGUAGE 'plpgsql' STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
-- Dynamic ORDER BY CASE expressions need a per-call plan (see get_proposals).
SET plan_cache_mode = force_custom_plan
AS $$
DECLARE
  __offset INT       := ((_page - 1) * _page_size);
  _now     TIMESTAMP := (SELECT created_at FROM hive.blocks_view WHERE num = hafbe_backend.get_hafbe_head_block());
BEGIN
  RETURN QUERY (
    WITH limited_set AS MATERIALIZED (
      SELECT cpv.voter_id, cpv.proposal_id, cpv.source_op
      FROM hafbe_app.current_proposal_votes cpv
      JOIN hafbe_app.current_proposals      cp  ON cp.proposal_id = cpv.proposal_id
      WHERE hafbe_backend.proposal_status_matches(_status, cp.start_date, cp.end_date, cp.removed, _now)
        AND (_proposal_id IS NULL OR cpv.proposal_id = _proposal_id)
        AND (_voter_id    IS NULL OR cpv.voter_id    = _voter_id)
      ORDER BY
        (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'asc'  THEN cpv.voter_id    END) ASC,
        (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'desc' THEN cpv.voter_id    END) DESC,
        (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'asc'  THEN cpv.proposal_id END) ASC,
        (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'desc' THEN cpv.proposal_id END) DESC,
        (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'asc'  THEN cpv.proposal_id END) ASC,
        (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'desc' THEN cpv.proposal_id END) DESC,
        (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'asc'  THEN cpv.voter_id    END) ASC,
        (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'desc' THEN cpv.voter_id    END) DESC
      OFFSET __offset
      LIMIT _page_size
    )
    SELECT
      av.name::TEXT       AS voter_name,
      ROW(
        cp.proposal_id,
        cp.proposal_id,
        cav.name::TEXT,
        rav.name::TEXT,
        cp.start_date,
        cp.end_date,
        cp.daily_pay::TEXT,
        cp.subject,
        cp.permlink,
        COALESCE(vsc.total_votes, 0)::TEXT,
        COALESCE(vsc.voters_num, 0),
        cp.paid_amount::TEXT,
        (CASE
          WHEN _now > cp.end_date   THEN 'expired'
          WHEN _now < cp.start_date THEN 'inactive'
          ELSE                            'active'
        END)::TEXT
      )::hafbe_backend.proposal AS proposal,
      (CASE
        WHEN cap.account_id IS NOT NULL THEN '0'
        ELSE COALESCE(avs.vests, 0)::TEXT
      END)                                       AS voter_vests,
      COALESCE(avs.account_vests, 0)::TEXT        AS direct_vests,
      COALESCE(avs.proxied_vests, 0)::TEXT        AS proxied_vests,
      COALESCE(pav.name, '')::TEXT                AS proxy,
      bv.created_at                               AS "timestamp"
    FROM limited_set ls
    JOIN hafbe_app.accounts_view              av  ON av.id           = ls.voter_id
    JOIN hafbe_app.current_proposals          cp  ON cp.proposal_id  = ls.proposal_id
    JOIN hafbe_app.accounts_view              cav ON cav.id          = cp.creator_id
    JOIN hafbe_app.accounts_view              rav ON rav.id          = cp.receiver_id
    LEFT JOIN hafbe_app.proposal_vote_stats_cache vsc ON vsc.proposal_id  = cp.proposal_id
    LEFT JOIN hafbe_app.account_vest_stats_cache  avs ON avs.account_id   = ls.voter_id
    LEFT JOIN hafbe_app.current_account_proxies   cap ON cap.account_id   = ls.voter_id
    LEFT JOIN hafbe_app.accounts_view             pav ON pav.id           = cap.proxy_id
    JOIN hive.blocks_view                     bv  ON bv.num          = hafd.operation_id_to_block_num(ls.source_op)
    ORDER BY
      (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'asc'  THEN ls.voter_id    END) ASC,
      (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'desc' THEN ls.voter_id    END) DESC,
      (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'asc'  THEN ls.proposal_id END) ASC,
      (CASE WHEN _sort = 'by_voter_proposal' AND _direction = 'desc' THEN ls.proposal_id END) DESC,
      (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'asc'  THEN ls.proposal_id END) ASC,
      (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'desc' THEN ls.proposal_id END) DESC,
      (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'asc'  THEN ls.voter_id    END) ASC,
      (CASE WHEN _sort = 'by_proposal_voter' AND _direction = 'desc' THEN ls.voter_id    END) DESC
  );
END $$;

-- =============================================================================
-- SECTION 5: Proposal Vote Stats Cache - Period Aggregation
-- =============================================================================

/*
 * get_proposal_vote_stats_history: Historical proposal vote stats by time period.
 *
 * Generates a time-series of proposal vote statistics using the same period
 * skeleton as witness timeline and transaction stats.
 *
 * OPTIMIZATION: If querying up to current head block, the LATEST period reads
 * DIRECTLY from proposal_vote_stats_cache (same as get_proposals), guaranteeing
 * 100% consistency with the proposal list. Historical periods recompute from
 * proposal_votes_history using the EXACT SAME stake-weighting logic as the
 * cache refresh function (direct voters only, excluding governance proxies).
 *
 * PARAMETERS:
 *   _ctx - Unified period+list+direction context (from resolve_period_list_context)
 *
 * RETURNS: Set of proposal_vote_stats_history_record records (paginated)
 *
 * CACHE-ALIGNED LOGIC (100% match with get_proposals):
 *   - Latest period: SUM(total_votes) / SUM(voters_num) FROM proposal_vote_stats_cache
 *   - Historical periods: Same stake-weighting as process_proposal_vote_stats_cache()
 *   - Excludes voters who have set a governance proxy
 *
 * UNIFIED PATTERN:
 *   1. resolve_period_list_context() - parse all params at once
 *   2. generate_time_buckets() - complete period coverage
 *   3. LEFT JOIN with cache (latest) + historical recomputation
 *   4. LATERAL JOIN find_nearest_block_before() - fill missing last_block_num
 *   5. adjust_to_period_end() - date normalization
 *   6. OFFSET/LIMIT - pagination window
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_proposal_vote_stats_history;
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposal_vote_stats_history(
    _ctx hafbe_backend.period_list_context
)
RETURNS SETOF hafbe_backend.proposal_vote_stats_history_record
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  _head_block INT := hive.app_get_irreversible_block();
  _is_latest  BOOLEAN;
BEGIN
  _is_latest := (_ctx.period.to_block IS NULL OR _ctx.period.to_block >= _head_block);

  RETURN QUERY (
    WITH date_series AS (
      SELECT hafbe_backend.generate_time_buckets(_ctx.period) AS period
    ),
    period_boundaries AS (
      SELECT
        ds.period,
        hafbe_backend.find_nearest_block_before(ds.period + _ctx.period.one_period) AS period_end_block,
        (ds.period + _ctx.period.one_period) >= CURRENT_TIMESTAMP AS is_current_period
      FROM date_series ds
    ),
    current_cache_stats AS MATERIALIZED (
      SELECT
        COALESCE(SUM(total_votes), 0)::BIGINT AS total_votes,
        SUM(voters_num)::INT                   AS voters_num
      FROM hafbe_app.proposal_vote_stats_cache
      WHERE _is_latest
    ),
    historical_votes AS MATERIALIZED (
      SELECT
        pb.period,
        COUNT(DISTINCT pvh.voter_id)::INT AS voters_num,
        SUM(CASE
              WHEN pvh.approve AND NOT EXISTS (
                SELECT 1 FROM hafbe_app.current_account_proxies cap WHERE cap.account_id = pvh.voter_id
              )
              THEN COALESCE(avs.vests, 0)
              ELSE 0
            END)::BIGINT AS total_votes,
        MAX(pvh.source_op_block)::INT AS last_block_num
      FROM period_boundaries pb
      JOIN hafbe_backend.proposal_votes_history_view pvh
        ON pvh.source_op_block <= pb.period_end_block
      LEFT JOIN hafbe_backend.expired_voter_stats_view avs ON avs.account_id = pvh.voter_id
      WHERE pvh.approve = TRUE
        AND (pb.period_end_block BETWEEN _ctx.period.from_block AND _ctx.period.to_block)
        AND NOT pb.is_current_period
      GROUP BY pb.period
    ),
    all_period_stats AS (
      SELECT
        pb.period,
        CASE
          WHEN pb.is_current_period AND _is_latest THEN ccs.total_votes
          ELSE COALESCE(hv.total_votes, 0)
        END AS total_votes,
        CASE
          WHEN pb.is_current_period AND _is_latest THEN ccs.voters_num
          ELSE COALESCE(hv.voters_num, 0)
        END AS voters_num,
        CASE
          WHEN pb.is_current_period AND _is_latest THEN _head_block
          ELSE hv.last_block_num
        END AS last_block_num
      FROM period_boundaries pb
      CROSS JOIN current_cache_stats ccs
      LEFT JOIN historical_votes hv ON pb.period = hv.period
    ),
    join_missing_block AS (
      SELECT
        aps.period,
        aps.total_votes,
        aps.voters_num,
        COALESCE(aps.last_block_num, pb.period_end_block) AS last_block_num
      FROM all_period_stats aps
      JOIN period_boundaries pb ON aps.period = pb.period
    )
    SELECT
      hafbe_backend.adjust_to_period_end(jmb.period, _ctx.period.one_period) AS date,
      jmb.total_votes::TEXT,
      jmb.voters_num,
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

/*
 * get_proposal_vote_stats_history_count: Count total time periods for proposal stats history.
 *
 * Used by endpoint wrapper to calculate total_pages. Counts the number of
 * time buckets that would be returned by get_proposal_vote_stats_history.
 */
DROP FUNCTION IF EXISTS hafbe_backend.get_proposal_vote_stats_history_count;
CREATE OR REPLACE FUNCTION hafbe_backend.get_proposal_vote_stats_history_count(
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

RESET ROLE;

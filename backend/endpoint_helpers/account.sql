-- =============================================================================
-- Account Helper Functions
-- =============================================================================
-- Functions for retrieving various account-related information including
-- proxied votes, witness votes, profile data, and account parameters.
-- =============================================================================

SET ROLE hafbe_owner;

-- =============================================================================
-- SECTION 1: Type Definitions
-- =============================================================================
-- Types used by the helper functions in this file.

/*
 * account_votes: Witness voting data for an account.
 *
 * FIELDS:
 *   witnesses_voted_for - Count of witnesses this account has voted for
 *   witness_votes       - Array of witness account names voted for
 */
DROP TYPE IF EXISTS hafbe_backend.account_votes CASCADE;
CREATE TYPE hafbe_backend.account_votes AS (
    witnesses_voted_for INT,
    witness_votes       TEXT[]
);

/*
 * account_parameters: Account configuration data from the blockchain.
 *
 * FIELDS:
 *   can_vote                 - Whether account can vote (may be disabled)
 *   mined                    - Whether account was created via mining (POW)
 *   recovery_account         - Account designated for recovery operations
 *   last_account_recovery    - Timestamp of last recovery operation
 *   created                  - Account creation timestamp
 *   pending_claimed_accounts - Number of pending account creation tokens
 */
DROP TYPE IF EXISTS hafbe_backend.account_parameters CASCADE;
CREATE TYPE hafbe_backend.account_parameters AS (
    can_vote                 BOOLEAN,
    mined                    BOOLEAN,
    recovery_account         TEXT,
    last_account_recovery    TIMESTAMP,
    created                  TIMESTAMP,
    pending_claimed_accounts INT
);

/*
 * json_metadata: Account JSON metadata fields.
 *
 * FIELDS:
 *   json_metadata         - Main profile metadata (owner key required)
 *   posting_json_metadata - Posting-level metadata (posting key can update)
 */
DROP TYPE IF EXISTS hafbe_backend.json_metadata CASCADE;
CREATE TYPE hafbe_backend.json_metadata AS (
    json_metadata         TEXT,
    posting_json_metadata TEXT
);

-- =============================================================================
-- SECTION 2: Proxy and Voting Functions
-- =============================================================================

/*
 * get_account_proxied_vsf_votes: Gets proxied vest values by proxy level.
 *
 * Returns an array of 4 values representing proxied vests at each level.
 * Hive supports up to 4 levels of proxy delegation.
 *
 * PARAMETERS:
 *   _account - Account ID to get proxied votes for
 *
 * RETURNS: TEXT array of 4 elements [level1, level2, level3, level4]
 *          Each value is '0' if no proxy at that level
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_proxied_vsf_votes(_account INT)
RETURNS TEXT[]
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    /*
     * =========================================================================
     * CTE: proxy_levels
     * =========================================================================
     * PURPOSE: Fetch actual proxied vests at each level for this account.
     */
    WITH proxy_levels AS MATERIALIZED (
      SELECT
        vpvv.proxied_vests AS proxy,
        vpvv.proxy_level
      FROM hafbe_backend.voters_proxied_vests_view vpvv
      WHERE vpvv.proxy_id = _account
      ORDER BY vpvv.proxy_level
    ),

    /*
     * =========================================================================
     * CTE: populate_record
     * =========================================================================
     * PURPOSE: Create placeholder rows for all 4 proxy levels.
     *
     * This ensures we always return exactly 4 values even if some
     * levels have no proxied vests.
     */
    populate_record AS MATERIALIZED (
      SELECT '0' AS proxy, 1 AS proxy_level
      UNION ALL SELECT '0', 2
      UNION ALL SELECT '0', 3
      UNION ALL SELECT '0', 4
    )

    SELECT array_agg(COALESCE(s.proxy::TEXT, pr.proxy) ORDER BY pr.proxy_level)
    FROM populate_record pr
    LEFT JOIN proxy_levels s ON s.proxy_level = pr.proxy_level
  );
END
$$;

/*
 * get_account_witness_votes: Gets witnesses that an account has voted for.
 *
 * PARAMETERS:
 *   _account - Account ID to get witness votes for
 *
 * RETURNS: account_votes with count and array of witness names
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_witness_votes(_account INT)
RETURNS hafbe_backend.account_votes
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    WITH votes AS (
      SELECT av.name AS vote
      FROM hafbe_backend.current_witness_votes_view cwvv
      JOIN hive.accounts_view av ON av.id = cwvv.witness_id
      WHERE cwvv.voter_id = _account
    )
    SELECT (
      COUNT(*)::INT,
      array_agg(v.vote ORDER BY v.vote)
    )::hafbe_backend.account_votes
    FROM votes v
  );
END
$$;

/*
 * get_account_proxy: Gets the current proxy account for an account.
 *
 * When an account sets a proxy, their witness votes are delegated
 * to the proxy account.
 *
 * PARAMETERS:
 *   _account - Account ID to get proxy for
 *
 * RETURNS: Proxy account name or NULL if no proxy set
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_proxy(_account INT)
RETURNS TEXT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    SELECT av.name
    FROM hive.accounts_view av
    WHERE av.id = cap.proxy_id
  )
  FROM hafbe_backend.current_account_proxies_view cap
  WHERE cap.account_id = _account;
END
$$;

-- =============================================================================
-- SECTION 3: Profile and Metadata Functions
-- =============================================================================

/*
 * parse_profile_picture: Extracts profile image URL from metadata JSON.
 *
 * Tries json_metadata first, then falls back to posting_json_metadata.
 * Handles invalid JSON gracefully by returning NULL.
 *
 * PARAMETERS:
 *   json_metadata         - Main account metadata JSON string
 *   posting_json_metadata - Posting metadata JSON string
 *
 * RETURNS: Profile image URL or NULL if not found/invalid
 */
CREATE OR REPLACE FUNCTION hafbe_backend.parse_profile_picture(
    json_metadata         TEXT,
    posting_json_metadata TEXT
)
RETURNS TEXT
LANGUAGE 'plpgsql' IMMUTABLE
AS
$$
DECLARE
  __profile_image_url TEXT;
BEGIN
  -- Try main metadata first
  BEGIN
    __profile_image_url := json_metadata::JSON -> 'profile' ->> 'profile_image';
  EXCEPTION WHEN invalid_text_representation THEN
    __profile_image_url := NULL;
  END;

  -- Fall back to posting metadata if not found
  IF __profile_image_url IS NULL THEN
    BEGIN
      __profile_image_url := posting_json_metadata::JSON -> 'profile' ->> 'profile_image';
    EXCEPTION WHEN invalid_text_representation THEN
      __profile_image_url := NULL;
    END;
  END IF;

  RETURN __profile_image_url;
END
$$;

/*
 * get_json_metadata: Retrieves account metadata JSON fields.
 *
 * PARAMETERS:
 *   _account - Account ID to get metadata for
 *
 * RETURNS: json_metadata type with both metadata fields
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_json_metadata(_account INT)
RETURNS hafbe_backend.json_metadata
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    SELECT ROW(
      m.json_metadata,
      m.posting_json_metadata
    )
    FROM hafd.hafbe_app_metadata m
    WHERE m.account_id = _account
  );
END
$$;

-- =============================================================================
-- SECTION 4: Account Statistics Functions
-- =============================================================================

/*
 * get_account_ops_count: Gets total operation count for an account.
 *
 * Uses the account_op_seq_no which is a sequential counter for all
 * operations involving this account.
 *
 * PARAMETERS:
 *   _account - Account ID to get operation count for
 *
 * RETURNS: Total number of operations (seq_no + 1 since 0-indexed)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_ops_count(_account INT)
RETURNS INT
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  -- account_op_seq_no is 0-indexed, so add 1 for count
  RETURN aov.account_op_seq_no + 1
  FROM hive.account_operations_view aov
  WHERE aov.account_id = _account
  ORDER BY aov.account_op_seq_no DESC
  LIMIT 1;
END
$$;

/*
 * get_account_last_vote: Gets timestamp of account's last effective vote.
 *
 * Finds the most recent effective_comment_vote operation where the
 * account was the voter.
 *
 * PARAMETERS:
 *   _account - Account ID to get last vote for
 *
 * RETURNS: Timestamp of last vote or NULL if never voted
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_last_vote(_account INT)
RETURNS TIMESTAMP
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  __op_effective_comment_vote INT := hafbe_backend.op_effective_comment_vote();
BEGIN
  /*
   * NOTE: Uses operations_view_extended for timestamp.
   * Must verify the voter field matches since effective_comment_vote operations
   * are indexed by multiple accounts (author, voter, etc).
   */
  RETURN ov.timestamp
  FROM hive.account_operations_view aov
  JOIN hive.operations_view_extended ov ON ov.id = aov.operation_id
  WHERE
    aov.op_type_id = __op_effective_comment_vote AND
    aov.account_id = _account AND
    -- Verify this account is actually the voter, not just related to the op
    ov.body_value ->> 'voter' = (
      SELECT av.name FROM hive.accounts_view av WHERE av.id = _account
    )
  ORDER BY aov.account_op_seq_no DESC
  LIMIT 1;
END
$$;

-- =============================================================================
-- SECTION 5: Account Parameters Function
-- =============================================================================

/*
 * get_account_parameters: Retrieves account configuration parameters.
 *
 * These parameters are derived from various blockchain operations
 * and stored in the account_parameters table for efficient access.
 *
 * PARAMETERS:
 *   _account - Account ID to get parameters for
 *
 * RETURNS: account_parameters record with all config fields
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_parameters(_account INT)
RETURNS hafbe_backend.account_parameters
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN (
    SELECT ROW(
      ap.can_vote,
      ap.mined,
      ap.recovery_account,
      ap.last_account_recovery,
      ap.created,
      ap.pending_claimed_accounts
    )
    FROM hafbe_app.account_parameters ap
    WHERE ap.account = _account
  );
END
$$;

-- =============================================================================
-- SECTION 6: Account Activity Summary Function
-- =============================================================================

/*
 * get_account_activity_summary: Gets activity summary for an account within a block range.
 *
 * Uses a SINGLE CTE (verified_ops) that applies role-based participation checks
 * for every activity category. Both the per-category counts AND the last-activity
 * block/timestamp are derived from this same CTE, guaranteeing consistent results.
 *
 * PARAMETERS:
 *   _account    - Account ID to get activity for
 *   _from_block - Lower bound of the block range (NULL = genesis)
 *   _to_block   - Upper bound of the block range (NULL = head)
 *
 * RETURNS: account_activity_summary record with operation counts and last activity
 *
 * DESIGN:
 *   1. verified_ops CTE: fetches ALL activity-category ops for the account within
 *      the block range, joins body_value, and tags each row with its resolved
 *      activity category using get_activity_op_types(). Then filters through
 *      check_account_participation() so only role-verified rows survive.
 *
 *   2. Per-category counts: simple FILTER clauses over verified_ops.
 *
 *   3. Last activity: MAX(block_num) and the corresponding timestamp from
 *      verified_ops -- no separate query needed, same participation rules.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_account_activity_summary(
    _account    INT,
    _from_block INT,
    _to_block   INT
)
RETURNS hafbe_backend.account_activity_summary
LANGUAGE 'plpgsql' STABLE
SET JIT = OFF
SET from_collapse_limit = 16
SET join_collapse_limit = 16
AS
$$
DECLARE
  __hafbe_current_block INT := (SELECT current_block_num FROM hafd.contexts WHERE name = 'hafbe_app');
  __range               hafbe_backend.blocksearch_filter_return;
  __transfer_types      INT[] := hafbe_backend.get_activity_op_types('transfer');
  __comment_types       INT[] := hafbe_backend.get_activity_op_types('comment');
  __vote_types          INT[] := hafbe_backend.get_activity_op_types('vote');
  __witness_vote_types  INT[] := hafbe_backend.get_activity_op_types('witness_vote');
  __proposal_vote_types INT[] := hafbe_backend.get_activity_op_types('proposal_vote');
  __all_op_types        INT[];
  __account_name        TEXT;
  __result              hafbe_backend.account_activity_summary;
BEGIN
  -- Normalize block range using existing blocksearch helper
  SELECT from_block, to_block
  INTO __range.from_block, __range.to_block
  FROM hafbe_backend.blocksearch_range(_from_block, _to_block, __hafbe_current_block);

  __account_name := (SELECT av.name FROM hive.accounts_view av WHERE av.id = _account);
  IF __account_name IS NULL THEN
    RETURN NULL;
  END IF;

  __all_op_types := array_cat(
    array_cat(__transfer_types, __comment_types),
    array_cat(
      array_cat(__vote_types, __witness_vote_types),
      __proposal_vote_types
    )
  );

  IF array_length(__all_op_types, 1) IS NULL THEN
    RETURN NULL;
  END IF;

  -- Single CTE: verified_ops filters every row through role-based participation.
  -- Both per-category counts and last-activity derive from the same set.
  SELECT ROW(
    __account_name,
    (__range.from_block, __range.to_block)::hafbe_backend.block_range,
    COALESCE(SUM(CASE WHEN vo.op_type_id = ANY(__transfer_types)      THEN 1 END), 0)::INT,
    COALESCE(SUM(CASE WHEN vo.op_type_id = ANY(__comment_types)       THEN 1 END), 0)::INT,
    COALESCE(SUM(CASE WHEN vo.op_type_id = ANY(__vote_types)          THEN 1 END), 0)::INT,
    COALESCE(SUM(CASE WHEN vo.op_type_id = ANY(__witness_vote_types)  THEN 1 END), 0)::INT,
    COALESCE(SUM(CASE WHEN vo.op_type_id = ANY(__proposal_vote_types) THEN 1 END), 0)::INT,
    MAX(vo.block_num),
    (SELECT bv.created_at FROM hive.blocks_view bv WHERE bv.num = MAX(vo.block_num))
  )::hafbe_backend.account_activity_summary
  INTO __result
  FROM (
    -- verified_ops: the SINGLE source of truth for all activity in this summary
    SELECT aov.block_num, aov.op_type_id
    FROM hive.account_operations_view aov
    JOIN hive.operations_view_extended ov ON ov.id = aov.operation_id
    WHERE aov.account_id = _account
      AND aov.op_type_id = ANY(__all_op_types)
      AND aov.block_num >= __range.from_block
      AND aov.block_num <= __range.to_block
      AND (
        -- Per-category participation verification (same rules as count_account_activity)
        (aov.op_type_id = ANY(__transfer_types)      AND hafbe_backend.check_account_participation('transfer',       ov.body_value, __account_name)) OR
        (aov.op_type_id = ANY(__comment_types)        AND hafbe_backend.check_account_participation('comment',        ov.body_value, __account_name)) OR
        (aov.op_type_id = ANY(__vote_types)           AND hafbe_backend.check_account_participation('vote',           ov.body_value, __account_name)) OR
        (aov.op_type_id = ANY(__witness_vote_types)   AND hafbe_backend.check_account_participation('witness_vote',   ov.body_value, __account_name)) OR
        (aov.op_type_id = ANY(__proposal_vote_types)  AND hafbe_backend.check_account_participation('proposal_vote',  ov.body_value, __account_name))
      )
  ) vo;

  RETURN __result;
END
$$;

RESET ROLE;

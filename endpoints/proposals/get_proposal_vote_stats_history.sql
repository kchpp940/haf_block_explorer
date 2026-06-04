SET ROLE hafbe_owner;

/** openapi:paths
/proposals/vote-stats-history:
  get:
    tags:
      - Proposals
    summary: Proposal vote statistics history
    description: |
      History of proposal vote statistics aggregated by day, month or year.
      Uses the same stake-weighting logic as proposal_vote_stats_cache
      (direct voters only, excluding those with governance proxies).

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_proposal_vote_stats_history();`

      REST call example
      * `GET ''https://%1$s/hafbe-api/proposals/vote-stats-history''`
    operationId: hafbe_endpoints.get_proposal_vote_stats_history
    parameters:
      - in: query
        name: granularity
        required: false
        schema:
          $ref: '#/components/schemas/hafbe_backend.granularity'
          default: monthly
        description: |
          granularity types:

          * daily

          * monthly

          * yearly
      - in: query
        name: direction
        required: false
        schema:
          $ref: '#/components/schemas/hafbe_backend.sort_direction'
          default: desc
        description: |
          Sort order:

           * `asc` - Ascending, from oldest to newest 

           * `desc` - Descending, from newest to oldest 
      - in: query
        name: page-size
        required: false
        schema:
          type: integer
          default: 100
        description: Number of time periods per page
      - in: query
        name: page
        required: false
        schema:
          type: integer
          default: 1
        description: Page number (1-indexed)
      - in: query
        name: from-block
        required: false
        schema:
          type: string
          default: NULL
        description: |
          Lower limit of the block range, can be represented either by a block-number (integer) or a timestamp (in the format YYYY-MM-DD HH:MI:SS).
      - in: query
        name: to-block
        required: false
        schema:
          type: string
          default: NULL
        description: | 
          Similar to the from-block parameter, can either be a block-number (integer) or a timestamp (formatted as YYYY-MM-DD HH:MI:SS). 
    responses:
      '200':
        description: |
          Proposal vote statistics history

          * Returns `hafbe_backend.proposal_vote_stats_history`
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.proposal_vote_stats_history'
            example:
              total_periods: 12
              total_pages: 1
              history:
                - date: "2023-12-01T00:00:00"
                  total_votes: "50000000000"
                  voters_num: 1250
                  last_block_num: 78000000

      '404':
        description: No proposal vote statistics found
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_proposal_vote_stats_history;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_proposal_vote_stats_history(
    "granularity" hafbe_backend.granularity = 'monthly',
    "direction" hafbe_backend.sort_direction = 'desc',
    "page-size" INT = 100,
    "page" INT = 1,
    "from-block" TEXT = NULL,
    "to-block" TEXT = NULL
)
RETURNS hafbe_backend.proposal_vote_stats_history 
-- openapi-generated-code-end
LANGUAGE 'plpgsql'
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
AS
$$
DECLARE
  _ctx            hafbe_backend.period_list_context := hafbe_backend.resolve_period_list_context("granularity", "direction", "from-block", "to-block", "page-size", "page", 1000);
  _total_periods  INT;
  _total_pages    INT;
  _result         hafbe_backend.proposal_vote_stats_history_record[];
BEGIN
  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);

  _total_periods := hafbe_backend.get_proposal_vote_stats_history_count("granularity", _ctx.list.block_range.first_block, _ctx.list.block_range.last_block);
  _total_pages   := hafbe_backend.validate_and_compute_pages(_total_periods, _ctx.list.page_size, _ctx.list.page);

  _result := array_agg(row) FROM (
    SELECT
      ba.date,
      ba.total_votes,
      ba.voters_num,
      ba.last_block_num
    FROM hafbe_backend.get_proposal_vote_stats_history(_ctx) ba
  ) row;

  RETURN (
    COALESCE(_total_periods, 0),
    COALESCE(_total_pages, 0),
    COALESCE(_result, '{}'::hafbe_backend.proposal_vote_stats_history_record[])
  )::hafbe_backend.proposal_vote_stats_history;

END
$$;

RESET ROLE;

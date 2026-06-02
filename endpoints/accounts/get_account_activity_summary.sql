SET ROLE hafbe_owner;

/** openapi:paths
/accounts/{account-name}/activity-summary:
  get:
    tags:
      - Accounts
    summary: Get account activity summary by operation type
    description: |
      Get aggregated account activity counts for core operation types (transfer,
      comment, vote, witness vote, proposal vote) within a specified block range,
      plus the most recent activity block and timestamp.

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_account_activity_summary(''blocktrades'');`
      * `SELECT * FROM hafbe_endpoints.get_account_activity_summary(''blocktrades'', ''1000000'', ''2000000'');`
      * `SELECT * FROM hafbe_endpoints.get_account_activity_summary(''blocktrades'', ''2023-01-01 00:00:00'', ''2023-12-31 23:59:59'');`

      REST call example
      * `GET ''https://%1$s/hafbe-api/accounts/blocktrades/activity-summary''`
      * `GET ''https://%1$s/hafbe-api/accounts/blocktrades/activity-summary?from-block=1000000&to-block=2000000''`
      * `GET ''https://%1$s/hafbe-api/accounts/blocktrades/activity-summary?from-block=2023-01-01&to-block=2023-12-31''`
    operationId: hafbe_endpoints.get_account_activity_summary
    parameters:
      - in: path
        name: account-name
        required: true
        schema:
          type: string
        description: Name of the account
      - in: query
        name: from-block
        required: false
        schema:
          type: string
          default: NULL
        description: |
          Lower bound of the block range. Either a block-number (integer) or a
          timestamp (`YYYY-MM-DD HH:MI:SS`). When a timestamp is given, it is
          converted to the first block whose `created_at >= timestamp`.
      - in: query
        name: to-block
        required: false
        schema:
          type: string
          default: NULL
        description: |
          Upper bound of the block range. Same format as `from-block`.
          When a timestamp is given, it is converted to the last block whose
          `created_at <= timestamp`.
    responses:
      '200':
        description: |
          Account activity summary with operation counts and last activity info.

          * Returns `hafbe_backend.account_activity_summary`
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.account_activity_summary'
            example: {
              "account": "blocktrades",
              "block_range": {
                "from": 1,
                "to": 5000000
              },
              "transfers": 1250,
              "comments": 342,
              "votes": 8915,
              "witness_votes": 47,
              "proposal_votes": 23,
              "last_activity_block": 4999987,
              "last_activity_timestamp": "2016-09-15T23:45:12"
            }
      '404':
        description: No such account in the database
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_account_activity_summary;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_account_activity_summary(
    "account-name" TEXT,
    "from-block" TEXT = NULL,
    "to-block" TEXT = NULL
)
RETURNS hafbe_backend.account_activity_summary 
-- openapi-generated-code-end
LANGUAGE 'plpgsql'
STABLE
SET JIT = OFF
SET join_collapse_limit = 16
SET from_collapse_limit = 16
AS
$$
DECLARE
  _block_range    hive.blocks_range := hive.convert_to_blocks_range("from-block", "to-block");
  _head_block_num INT               := hafbe_backend.get_hafbe_head_block();
  _account_id     INT               := hafah_backend.get_account_id("account-name", TRUE);
BEGIN
  -- Validate block range doesn't exceed head block
  PERFORM hafbe_backend.validate_block_num_too_high(_block_range.first_block, _head_block_num);

  -- Set cache headers based on whether the range is fully within irreversible blocks
  IF _block_range.last_block <= hive.app_get_irreversible_block() AND _block_range.last_block IS NOT NULL THEN
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=31536000"}]', true);
  ELSE
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);
  END IF;

  RETURN hafbe_backend.get_account_activity_summary(
    _account_id,
    _block_range.first_block,
    _block_range.last_block
  );
END
$$;

RESET ROLE;
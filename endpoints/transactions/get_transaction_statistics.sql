SET ROLE hafbe_owner;

/** openapi:paths
/transaction-statistics:
  get:
    tags:
      - Transactions
    summary: Aggregated transaction statistics
    description: |
      History of amount of transactions per day, month or year, broken down
      by operation group (governance, token, account, comment, witness, market, other).

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_transaction_statistics();`

      REST call example
      * `GET ''https://%1$s/hafbe-api/transaction-statistics''`
    operationId: hafbe_endpoints.get_transaction_statistics
    parameters:
      - in: query
        name: granularity
        required: false
        schema:
          $ref: '#/components/schemas/hafbe_backend.granularity'
          default: yearly
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
        name: from-block
        required: false
        schema:
          type: string
          default: NULL
        description: |
          Lower limit of the block range, can be represented either by a block-number (integer) or a timestamp (in the format YYYY-MM-DD HH:MI:SS).

          The provided `timestamp` will be converted to a `block-num` by finding the first block 
          where the block''s `created_at` is more than or equal to the given `timestamp` (i.e. `block''s created_at >= timestamp`).

          The function will interpret and convert the input based on its format, example input:

          * `2016-09-15 19:47:21`

          * `5000000`
      - in: query
        name: to-block
        required: false
        schema:
          type: string
          default: NULL
        description: | 
          Similar to the from-block parameter, can either be a block-number (integer) or a timestamp (formatted as YYYY-MM-DD HH:MI:SS). 

          The provided `timestamp` will be converted to a `block-num` by finding the first block 
          where the block''s `created_at` is less than or equal to the given `timestamp` (i.e. `block''s created_at <= timestamp`).
          
          The function will convert the value depending on its format, example input:

          * `2016-09-15 19:47:21`

          * `5000000`
      - in: query
        name: operation-group
        required: false
        schema:
          type: array
          items:
            $ref: '#/components/schemas/hafbe_backend.operation_group'
          default: NULL
        style: form
        explode: false
        description: |
          Optional filter to include only specific operation groups.
          Omit to return all groups.

          Operation groups:

          * governance - Proposals, witness voting, governance-related operations

          * token - Transfers, power up/down, rewards

          * account - Account creation, recovery, profile updates

          * comment - Posts, comments, votes

          * witness - Block production, feed publishing

          * market - Limit orders

          * other - All other operations
    responses:
      '200':
        description: |
          Returns array of `hafbe_backend.operation_group_stats`.
          Each period contains total_transactions, total_operations,
          and a `groups` array with per-group breakdown.
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.array_of_operation_group_stats'
            example: [
              {
                "date": "2017-01-01T00:00:00",
                "total_transactions": 6961192,
                "total_operations": 12345678,
                "groups": [
                  {"group": "comment", "op_count": 5000000, "trx_count": 0},
                  {"group": "governance", "op_count": 1200000, "trx_count": 0},
                  {"group": "token", "op_count": 3000000, "trx_count": 0}
                ],
                "last_block_num": 5000000
              }
            ]
            
      '404':
        description: No such account in the database
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_transaction_statistics;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_transaction_statistics(
    "granularity" hafbe_backend.granularity = 'yearly',
    "direction" hafbe_backend.sort_direction = 'desc',
    "from-block" TEXT = NULL,
    "to-block" TEXT = NULL,
    "operation-group" hafbe_backend.operation_group[] = NULL
)
RETURNS SETOF hafbe_backend.operation_group_stats 
-- openapi-generated-code-end
LANGUAGE 'plpgsql'
SET jit = OFF
AS
$$
DECLARE
  _block_range hive.blocks_range := hive.convert_to_blocks_range("from-block","to-block");
  _head_block_num INT            := hafbe_backend.get_hafbe_head_block();
BEGIN
  PERFORM hafbe_backend.validate_block_num_too_high(_block_range.first_block, _head_block_num);

  IF _block_range.last_block <= hive.app_get_irreversible_block() AND _block_range.last_block IS NOT NULL THEN
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=31536000"}]', true);
  ELSE
    PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=2"}]', true);
  END IF;

  RETURN QUERY (
    SELECT
      fb.date,
      fb.total_transactions,
      fb.total_operations,
      fb.groups,
      fb.last_block_num
    FROM hafbe_backend.get_operation_group_aggregation(
      "granularity",
      "direction",
      _block_range.first_block,
      _block_range.last_block,
      "operation-group"
    ) fb
  );

END
$$;

RESET ROLE;

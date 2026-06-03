SET ROLE hafbe_owner;

-- Witness page endpoint
/** openapi:paths
/witnesses/{account-name}/votes/timeline:
  get:
    tags:
      - Witnesses
    summary: Get daily aggregated vote changes for this witness.
    description: |
      Get a timeline of vote changes for this witness, aggregated by day.
      Each day shows the number of new votes, revoked votes, net proxied
      vests change, and net total vests change.

      The data source reuses the same witness votes history and resolved
      vote source as the `/votes/history` endpoint, so proxy cascades and
      expired account handling are already accounted for — no separate
      logic is needed.

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_witness_votes_timeline(''blocktrades'');`

      REST call example
      * `GET ''https://%1$s/hafbe-api/witnesses/blocktrades/votes/timeline?page-size=7''`
    operationId: hafbe_endpoints.get_witness_votes_timeline
    parameters:
      - in: path
        name: account-name
        required: true
        schema:
          type: string
        description: witness account name
      - in: query
        name: page
        required: false
        schema:
          type: integer
          default: 1
        description: |
          Return page on `page` number, defaults to `1`
      - in: query
        name: page-size
        required: false
        schema:
          type: integer
          default: 30
        description: Return max `page-size` days per page, defaults to `30`
      - in: query
        name: direction
        required: false
        schema:
          $ref: '#/components/schemas/hafbe_backend.sort_direction'
          default: desc
        description: |
          Sort order:

           * `asc` - Ascending, oldest date first

           * `desc` - Descending, newest date first
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
    responses:
      '200':
        description: |
          Daily aggregated vote changes for the witness

          * Returns `hafbe_backend.witness_votes_timeline`
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.witness_votes_timeline'
            example: {
              "total_days": 120,
              "total_pages": 4,
              "timeline": [
                {
                  "date": "2024-03-15",
                  "new_votes": 5,
                  "revoked_votes": 2,
                  "proxy_vests_change": "123456789012",
                  "net_vests": "9876543210987"
                },
                {
                  "date": "2024-03-14",
                  "new_votes": 3,
                  "revoked_votes": 0,
                  "proxy_vests_change": "0",
                  "net_vests": "5554443332221"
                }
              ]
            }
      '404':
        description: No such witness
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_witness_votes_timeline;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_witness_votes_timeline(
    "account-name" TEXT,
    "page" INT = 1,
    "page-size" INT = 30,
    "direction" hafbe_backend.sort_direction = 'desc',
    "from-block" TEXT = NULL,
    "to-block" TEXT = NULL
)
RETURNS hafbe_backend.witness_votes_timeline
-- openapi-generated-code-end
LANGUAGE 'plpgsql'
STABLE
SET from_collapse_limit = 16
SET join_collapse_limit = 16
SET jit = OFF
AS
$$
DECLARE
  _block_range hive.blocks_range := hive.convert_to_blocks_range("from-block","to-block");
  _head_block_num INT            := hafbe_backend.get_hafbe_head_block();
  _witness_id INT                := hafbe_backend.get_witness_id("account-name");
  _days_count INT;
  _total_pages INT;

  _result hafbe_backend.witness_votes_timeline_record[];
BEGIN
  PERFORM hafbe_backend.validate_limit("page-size", 10000);
  PERFORM hafbe_backend.validate_negative_limit("page-size");
  PERFORM hafbe_backend.validate_negative_page("page");
  PERFORM hafbe_backend.validate_block_num_too_high(_block_range.first_block, _head_block_num);

  PERFORM set_config('response.headers', '[{"Cache-Control": "public, max-age=60"}]', true);

  _days_count  := hafbe_backend.get_witness_votes_timeline_count(_witness_id, _block_range);
  _total_pages := hafah_backend.total_pages(_days_count, "page-size");

  PERFORM hafbe_backend.validate_page("page", _total_pages);

  _result := array_agg(row) FROM (
    SELECT
      ba.date,
      ba.new_votes,
      ba.revoked_votes,
      ba.proxy_vests_change,
      ba.net_vests
    FROM hafbe_backend.get_witness_votes_timeline(
      _witness_id,
      "page",
      "page-size",
      "direction",
      _block_range.first_block,
      _block_range.last_block
    ) ba
  ) row;

  RETURN (
    COALESCE(_days_count,0),
    COALESCE(_total_pages,0),
    COALESCE(_result, '{}'::hafbe_backend.witness_votes_timeline_record[])
  )::hafbe_backend.witness_votes_timeline;

END
$$;

RESET ROLE;

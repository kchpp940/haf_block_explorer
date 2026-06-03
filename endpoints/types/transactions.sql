SET ROLE hafbe_owner;

-- Transaction-related types for hafbe_backend

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.transaction_stats:
  type: object
  deprecated: true
  description: |
    Legacy type kept for internal helper use only.
    The /transaction-statistics endpoint now returns operation_group_stats.
  properties:
    date:
      type: string
      format: date-time
      description: the time transaction was included in the blockchain
    trx_count:
      type: integer
      description: amount of transactions
    avg_trx:
      type: integer
      description: avarage amount of transactions in block
    min_trx:
      type: integer
      description: minimal amount of transactions in block
    max_trx:
      type: integer
      description: maximum amount of transactions in block
    last_block_num:
      type: integer
      description: last block number in time range
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.transaction_stats CASCADE;
CREATE TYPE hafbe_backend.transaction_stats AS (
    "date" TIMESTAMP,
    "trx_count" INT,
    "avg_trx" INT,
    "min_trx" INT,
    "max_trx" INT,
    "last_block_num" INT
);
-- openapi-generated-code-end

/** openapi:components:schemas
hafbe_backend.array_of_transaction_stats:
  type: array
  items:
    $ref: '#/components/schemas/hafbe_backend.transaction_stats'
*/

----------------------------------------------------------------------
-- Internal-only helper types (no OpenAPI schema)
-- Used by backend/endpoint_helpers/transactions.sql dispatchers
----------------------------------------------------------------------

DROP TYPE IF EXISTS hafbe_backend.trx_stats CASCADE;
CREATE TYPE hafbe_backend.trx_stats AS (
    date           TIMESTAMP,
    trx_count      INT,
    count_blocks   INT,
    min_trx        INT,
    max_trx        INT,
    last_block_num INT
);

DROP TYPE IF EXISTS hafbe_backend.op_group_stats_flat CASCADE;
CREATE TYPE hafbe_backend.op_group_stats_flat AS (
    date           TIMESTAMP,
    op_group       hafbe_backend.operation_group,
    op_count       BIGINT,
    last_block_num INT
);

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.period_op_type_count:
  type: object
  properties:
    op_type_id:
      type: integer
      description: operation type identifier
    op_count:
      type: integer
      format: int64
      description: number of operations of this type in the period
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.period_op_type_count CASCADE;
CREATE TYPE hafbe_backend.period_op_type_count AS (
    "op_type_id" INT,
    "op_count" BIGINT
);
-- openapi-generated-code-end

/** openapi:components:schemas
hafbe_backend.operation_type_stats:
  type: object
  properties:
    date:
      type: string
      format: date-time
      description: end timestamp of the period (capped at current time for the in-progress period)
    total_transactions:
      type: integer
      format: int64
      description: total number of transactions in the period (from transaction_stats_by_day/month)
    total_operations:
      type: integer
      format: int64
      description: total number of operations in the period (sum of operations[].op_count)
    operations:
      type: array
      description: per-op-type breakdown for the period
      items:
        $ref: '#/components/schemas/hafbe_backend.period_op_type_count'
    last_block_num:
      type: integer
      description: last block number included in the period
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.operation_type_stats CASCADE;
CREATE TYPE hafbe_backend.operation_type_stats AS (
    "date" TIMESTAMP,
    "total_transactions" BIGINT,
    "total_operations" BIGINT,
    "operations" hafbe_backend.period_op_type_count[],
    "last_block_num" INT
);
-- openapi-generated-code-end

/** openapi:components:schemas
hafbe_backend.array_of_operation_type_stats:
  type: array
  items:
    $ref: '#/components/schemas/hafbe_backend.operation_type_stats'
*/

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.period_op_group_count:
  type: object
  properties:
    group:
      $ref: '#/components/schemas/hafbe_backend.operation_group'
      description: operation group identifier
    op_count:
      type: integer
      format: int64
      description: number of operations in this group
    trx_count:
      type: integer
      format: int64
      description: number of transactions containing operations from this group
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.period_op_group_count CASCADE;
CREATE TYPE hafbe_backend.period_op_group_count AS (
    "group" hafbe_backend.operation_group,
    "op_count" BIGINT,
    "trx_count" BIGINT
);
-- openapi-generated-code-end

/** openapi:components:schemas
hafbe_backend.operation_group_stats:
  type: object
  properties:
    date:
      type: string
      format: date-time
      description: end timestamp of the period (capped at current time for in-progress period)
    total_transactions:
      type: integer
      format: int64
      description: total number of transactions in the period
    total_operations:
      type: integer
      format: int64
      description: total number of operations in the period
    groups:
      type: array
      description: per-operation-group breakdown for the period
      items:
        $ref: '#/components/schemas/hafbe_backend.period_op_group_count'
    last_block_num:
      type: integer
      description: last block number included in the period
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.operation_group_stats CASCADE;
CREATE TYPE hafbe_backend.operation_group_stats AS (
    "date" TIMESTAMP,
    "total_transactions" BIGINT,
    "total_operations" BIGINT,
    "groups" hafbe_backend.period_op_group_count[],
    "last_block_num" INT
);
-- openapi-generated-code-end

/** openapi:components:schemas
hafbe_backend.array_of_operation_group_stats:
  type: array
  items:
    $ref: '#/components/schemas/hafbe_backend.operation_group_stats'
*/

RESET ROLE;

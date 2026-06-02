-- =============================================================================
-- Comment Operations Helper Functions
-- =============================================================================
-- Functions for retrieving operations related to a specific comment
-- (author + permlink combination). Used by the comment history endpoint.
--
-- Comment Instance Resolution:
-- Each comment_operation (op_type_id=1) creates a new comment instance. Each
-- delete_comment_operation (op_type_id=17) ends it. The instance is uniquely
-- identified by its creation op_id, and its lifecycle is the op_id range
-- [create_op_id, delete_op_id]. This range precisely binds all operations
-- (vote, edit, delete) to the target instance:
--
--   Instance 1: [create_op_id=100, delete_op_id=200]
--     → vote at op_id=150 belongs to instance 1
--     → vote at op_id=250 does NOT belong (outside range)
--
--   Instance 2: [create_op_id=300, delete_op_id=INT_MAX]
--     → vote at op_id=350 belongs to instance 2
--     → vote at op_id=150 does NOT belong (outside range)
--
-- Same-parent delete-and-recreate is handled naturally: even if both instances
-- share (author, permlink, parent_author, parent_permlink), their op_id ranges
-- are disjoint, so their operations never mix.
--
-- Target selection: the currently on-chain instance (last boundary was a create,
-- not a delete). If no such instance exists, returns empty result.
-- =============================================================================

SET ROLE hafbe_owner;

/*
 * _comment_instance_cte_sql: Returns CTE text that resolves the target comment
 * instance from creation/deletion operation boundaries. Both count and list
 * functions embed this identical CTE text, guaranteeing the same filter logic.
 *
 * CTE logic:
 *   1. boundary_ops     — all comment_operation(1) and delete_comment_operation(17)
 *                          for this author/permlink, ordered by op id
 *   2. create_boundaries — extract only the create operations, each starts an instance
 *   3. instance_ranges   — pair each create with its subsequent delete (if any)
 *                          to form [first_op_id, last_op_id] ranges
 *   4. active_instance   — the instance that is currently on-chain:
 *                          its create has no subsequent delete, OR the last
 *                          boundary operation is a create (not a delete)
 *
 * Output columns:
 *   first_op_id  — op id of the comment_operation that created this instance
 *   last_op_id   — op id of the delete_comment_operation that ends it,
 *                  or 9223372036854775807 (max BIGINT) if still active
 */
CREATE OR REPLACE FUNCTION hafbe_backend._comment_instance_cte_sql()
RETURNS TEXT
LANGUAGE 'plpgsql' STABLE
AS
$$
DECLARE
  __op_comment INT := hafbe_backend.op_comment();
  __op_delete  INT := hafbe_backend.op_delete_comment();
BEGIN
  RETURN format(
    $cte$
    boundary_ops AS (
      SELECT
        ov.id,
        ov.op_type_id
      FROM hive.operations_view ov
      WHERE
        ov.op_type_id IN (%s, %s) AND
        ov.body_value ->> 'author' = $1 AND
        ov.body_value ->> 'permlink' = $2
      ORDER BY ov.id
    ),
    create_boundaries AS (
      SELECT
        bo.id AS create_op_id
      FROM boundary_ops bo
      WHERE bo.op_type_id = %s
    ),
    instance_ranges AS (
      SELECT
        cb.create_op_id AS first_op_id,
        LEAD(cb.create_op_id) OVER (ORDER BY cb.create_op_id) AS next_create_op_id
      FROM create_boundaries cb
    ),
    active_instance AS (
      SELECT
        ir.first_op_id,
        CASE
          WHEN ir.next_create_op_id IS NOT NULL THEN ir.next_create_op_id - 1
          ELSE 9223372036854775807
        END AS last_op_id
      FROM instance_ranges ir
      WHERE NOT EXISTS (
        SELECT 1
        FROM boundary_ops del
        WHERE del.op_type_id = %s
          AND del.id > ir.first_op_id
          AND (ir.next_create_op_id IS NULL OR del.id < ir.next_create_op_id)
      )
      ORDER BY ir.first_op_id DESC
      LIMIT 1
    )
    $cte$,
    __op_comment, __op_delete, __op_comment, __op_delete
  );
END
$$;

/*
 * get_comment_operations_count: Counts operations for the active comment instance.
 *
 * Uses the same CTE as get_comment_operations. An operation is counted only if
 * its op id falls within the active instance's [first_op_id, last_op_id] range.
 *
 * RETURNS: Total count of matching operations (0 if no active instance)
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_comment_operations_count(
    _author          TEXT,
    _permlink        TEXT,
    _operation_types INT[]
)
RETURNS BIGINT
LANGUAGE 'plpgsql' STABLE
SET enable_hashjoin = OFF
AS
$$
DECLARE
  __cte TEXT := hafbe_backend._comment_instance_cte_sql();
BEGIN
  RETURN EXECUTE format(
    'WITH %s,
     target AS (SELECT * FROM active_instance)
     SELECT COUNT(*)
     FROM hive.operations_view ov
     CROSS JOIN target t
     WHERE
       ov.op_type_id = ANY($3) AND
       ov.body_value ->> ''author'' = $1 AND
       ov.body_value ->> ''permlink'' = $2 AND
       ov.id >= t.first_op_id AND
       ov.id <= t.last_op_id',
    __cte
  ) USING _author, _permlink, _operation_types;
END
$$;

/*
 * get_comment_operations: Retrieves operations for the active comment instance.
 *
 * Resolves the target instance by analyzing create/delete operation boundaries,
 * then returns all operations within the instance's op_id range.
 * The same CTE is embedded as in get_comment_operations_count, guaranteeing
 * identical filtering and consistent pagination totals.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_comment_operations(
    _author          TEXT,
    _permlink        TEXT,
    _operation_types INT[],
    _page_num        INT,
    _page_size       INT,
    _order_is        hafbe_backend.sort_direction,
    _body_limit      INT
)
RETURNS SETOF hafbe_backend.operation
LANGUAGE 'plpgsql' STABLE
SET enable_hashjoin = OFF
AS
$$
DECLARE
  __offset INT := ((_page_num - 1) * _page_size);
  __cte    TEXT := hafbe_backend._comment_instance_cte_sql();
BEGIN
  RETURN QUERY EXECUTE format(
    'WITH %s,
    target AS (SELECT * FROM active_instance),
    operation_range AS (
      SELECT
        ov.block_num,
        ov.id,
        ov.body,
        ov.op_pos,
        ov.trx_in_block,
        ov.op_type_id
      FROM hive.operations_view ov
      CROSS JOIN target t
      WHERE
        ov.op_type_id = ANY($3) AND
        ov.body_value ->> ''author'' = $1 AND
        ov.body_value ->> ''permlink'' = $2 AND
        ov.id >= t.first_op_id AND
        ov.id <= t.last_op_id
      ORDER BY
        (CASE WHEN $4 = ''desc'' THEN ov.id ELSE NULL END) DESC,
        (CASE WHEN $4 = ''asc''  THEN ov.id ELSE NULL END) ASC
      OFFSET $5
      LIMIT $6
    ),
    join_transactions AS (
      SELECT
        orr.body,
        orr.block_num,
        (
          SELECT encode(trx_hash, ''hex'')
          FROM hive.transactions_view
          WHERE block_num = orr.block_num AND trx_in_block = orr.trx_in_block
        ) AS trx_hash,
        orr.op_pos,
        orr.op_type_id,
        bv.created_at,
        hot.is_virtual,
        orr.id,
        orr.trx_in_block
      FROM operation_range orr
      JOIN hafd.operation_types hot ON hot.id = orr.op_type_id
      JOIN hive.blocks_view bv      ON bv.num = orr.block_num
    )
    SELECT
      (filtered_operations.composite).body,
      filtered_operations.block_num,
      filtered_operations.trx_hash,
      filtered_operations.op_pos,
      filtered_operations.op_type_id,
      filtered_operations.created_at,
      filtered_operations.is_virtual,
      filtered_operations.id::TEXT,
      filtered_operations.trx_in_block::SMALLINT
    FROM (
      SELECT
        hafah_backend.operation_body_filter(jt.body, jt.id, $7) AS composite,
        jt.block_num,
        jt.trx_hash,
        jt.op_pos,
        jt.op_type_id,
        jt.created_at,
        jt.is_virtual,
        jt.id,
        jt.trx_in_block
      FROM join_transactions jt
    ) filtered_operations
    ORDER BY
      (CASE WHEN $4 = ''desc'' THEN filtered_operations.id ELSE NULL END) DESC,
      (CASE WHEN $4 = ''asc''  THEN filtered_operations.id ELSE NULL END) ASC',
    __cte
  ) USING _author, _permlink, _operation_types, _order_is, __offset, _page_size, _body_limit;
END
$$;

RESET ROLE;

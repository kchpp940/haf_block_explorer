SET ROLE hafbe_owner;

-- ============================================================================
-- Convenience functions for commonly used operation types
-- These provide semantic names and avoid magic numbers scattered throughout the code
-- Each function returns the operation type ID by looking up the name in hafd.operation_types
-- ============================================================================

-- ============================================================================
-- Comment-related operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_vote()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::vote_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_comment()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_delete_comment()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::delete_comment_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_comment_options()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_options_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_author_reward()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::author_reward_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_curation_reward()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::curation_reward_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_comment_reward()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_reward_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_comment_payout_update()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_payout_update_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_comment_benefactor_reward()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::comment_benefactor_reward_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_effective_comment_vote()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::effective_comment_vote_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_ineffective_delete_comment()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::ineffective_delete_comment_operation');
END;
$$;

-- ============================================================================
-- Witness operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_account_witness_vote()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::account_witness_vote_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_account_witness_proxy()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::account_witness_proxy_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_proxy_cleared()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::proxy_cleared_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_producer_reward()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_reward_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_producer_missed()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::producer_missed_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_witness_update()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::witness_update_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_witness_set_properties()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::witness_set_properties_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_feed_publish()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::feed_publish_operation');
END;
$$;

-- ============================================================================
-- Account creation operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_account_create()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::account_create_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_create_claimed_account()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::create_claimed_account_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_account_create_with_delegation()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::account_create_with_delegation_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_account_created()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::account_created_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_claim_account()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::claim_account_operation');
END;
$$;

-- ============================================================================
-- Account recovery operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_recover_account()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::recover_account_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_changed_recovery_account()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::changed_recovery_account_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_expired_account_notification()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::expired_account_notification_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_decline_voting_rights()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::decline_voting_rights_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_declined_voting_rights()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::declined_voting_rights_operation');
END;
$$;

-- ============================================================================
-- Proof of work (mining) operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_pow()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::pow_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_pow2()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::pow2_operation');
END;
$$;

-- ============================================================================
-- Transfer operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_transfer()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_transfer_to_savings()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_to_savings_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_transfer_from_savings()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::transfer_from_savings_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_override_transfer()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::override_transfer_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_recurrent_transfer()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::recurrent_transfer_operation');
END;
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.op_fill_recurrent_transfer_operation()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::fill_recurrent_transfer_operation');
END;
$$;

-- ============================================================================
-- Helper: Get all transfer-related operation type IDs
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.get_transfer_op_types()
RETURNS INT[]
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN ARRAY[
    hafbe_backend.op_transfer(),
    hafbe_backend.op_transfer_to_savings(),
    hafbe_backend.op_transfer_from_savings(),
    hafbe_backend.op_override_transfer(),
    hafbe_backend.op_recurrent_transfer(),
    hafbe_backend.op_fill_recurrent_transfer_operation()
  ];
END;
$$;

-- ============================================================================
-- Proposal operations
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.op_update_proposal_votes()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN (SELECT id FROM hafd.operation_types WHERE name = 'hive::protocol::update_proposal_votes_operation');
END;
$$;

-- ============================================================================
-- Activity Category Mapping
-- ============================================================================
-- Maps operation types to activity categories and defines which JSON fields
-- identify account participation. This ensures consistent counting across
-- all account activity queries.
-- ============================================================================

/*
 * get_activity_op_types: Returns operation type IDs for a given activity category.
 *
 * Categories:
 *   - 'transfer'  - All transfer-related operations (transfer, savings, recurrent, override)
 *   - 'comment'   - Post and comment creation
 *   - 'vote'      - Post/comment votes
 *   - 'witness_vote' - Witness approval votes
 *   - 'proposal_vote' - DHF proposal approval votes
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_activity_op_types(_category TEXT)
RETURNS INT[]
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN CASE _category
    WHEN 'transfer' THEN hafbe_backend.get_transfer_op_types()
    WHEN 'comment' THEN ARRAY[hafbe_backend.op_comment()]
    WHEN 'vote' THEN ARRAY[hafbe_backend.op_vote()]
    WHEN 'witness_vote' THEN ARRAY[hafbe_backend.op_account_witness_vote()]
    WHEN 'proposal_vote' THEN ARRAY[hafbe_backend.op_update_proposal_votes()]
    ELSE ARRAY[]::INT[]
  END;
END;
$$;

/*
 * get_activity_account_field: Returns the JSON field name that identifies the
 * account's participation role for a given activity category.
 *
 * This field is used to verify an account's actual participation in an operation,
 * since account_operations_view indexes operations by all involved accounts.
 *
 * Returns NULL if the category uses a different verification method.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.get_activity_account_field(_category TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN CASE _category
    WHEN 'comment' THEN 'author'
    WHEN 'vote' THEN 'voter'
    WHEN 'witness_vote' THEN 'account'
    WHEN 'proposal_vote' THEN 'voter'
    ELSE NULL
  END;
END;
$$;

/*
 * check_account_participation: Verifies that an account actually participated
 * in an operation in the expected role for an activity category.
 *
 * PARAMETERS:
 *   _category     - Activity category ('transfer', 'comment', 'vote', etc.)
 *   _body         - JSON operation body from operations_view
 *   _account_name - Name of the account to verify
 *
 * RETURNS: TRUE if the account participated in the expected role, FALSE otherwise.
 *
 * For transfers, we count both sides (from AND to) since account_operations_view
 * already indexes both and the activity summary should reflect all transfer
 * involvement.
 */
CREATE OR REPLACE FUNCTION hafbe_backend.check_account_participation(
    _category     TEXT,
    _body         JSONB,
    _account_name TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE AS $$
DECLARE
  __field TEXT;
BEGIN
  -- Transfers: count both from and to (all involvement)
  IF _category = 'transfer' THEN
    RETURN (_body ->> 'from' = _account_name) OR (_body ->> 'to' = _account_name);
  END IF;

  -- Other categories: check the specific role field
  __field := hafbe_backend.get_activity_account_field(_category);
  IF __field IS NULL THEN
    RETURN TRUE;
  END IF;

  RETURN _body ->> __field = _account_name;
END;
$$;

-- ============================================================================
-- Helper functions: Operation type arrays for processing functions
-- ============================================================================

CREATE OR REPLACE FUNCTION hafbe_backend.get_comment_history_allowed_op_types()
RETURNS INT[] -- noqa: LT01, CP05
LANGUAGE 'plpgsql' STABLE
AS
$$
BEGIN
  RETURN ARRAY[
    hafbe_backend.op_vote(),                       -- 0: vote_operation
    hafbe_backend.op_comment(),                    -- 1: comment_operation
    hafbe_backend.op_delete_comment(),             -- 17: delete_comment_operation
    hafbe_backend.op_comment_options(),            -- 19: comment_options_operation
    hafbe_backend.op_author_reward(),              -- 51: author_reward_operation
    hafbe_backend.op_curation_reward(),            -- 52: curation_reward_operation
    hafbe_backend.op_comment_reward(),             -- 53: comment_reward_operation
    hafbe_backend.op_comment_payout_update(),      -- 61: comment_payout_update_operation
    hafbe_backend.op_comment_benefactor_reward(),  -- 63: comment_benefactor_reward_operation
    hafbe_backend.op_effective_comment_vote(),     -- 72: effective_comment_vote_operation
    hafbe_backend.op_ineffective_delete_comment()  -- 73: ineffective_delete_comment_operation
  ];
END
$$;

CREATE OR REPLACE FUNCTION hafbe_backend.get_comment_history_operation_types(
    _operations TEXT
)
RETURNS INT []-- noqa: LT01, CP05
LANGUAGE 'plpgsql' STABLE
SET JIT = OFF
AS
$$
DECLARE
  _allowed_ids   INT[] := hafbe_backend.get_comment_history_allowed_op_types();
  _operation_ids INT[] := (SELECT string_to_array(_operations, ',')::INT[]);
BEGIN
  IF _operations IS NULL THEN
    RETURN _allowed_ids;
  END IF;

  PERFORM hafah_backend.validate_operation_types(_operation_ids, _allowed_ids);

  RETURN _operation_ids;
END
$$;

RESET ROLE;

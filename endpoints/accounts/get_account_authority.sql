SET ROLE hafbe_owner;

/** openapi:paths
/accounts/{account-name}/authority:
  get:
    tags:
      - Accounts
    summary: Get account''s owner, active, posting, memo and witness signing authorities
    description: |
      Get information about account''s owner, active, posting, memo and witness signing authorities.

      SQL example
      * `SELECT * FROM hafbe_endpoints.get_account_authority(''blocktrades'');`

      REST call example
      * `GET ''https://%1$s/hafbe-api/accounts/blocktrades/authority''` 
    operationId: hafbe_endpoints.get_account_authority
    parameters:
      - in: path
        name: account-name
        required: true
        schema:
          type: string
        description: Name of the account
    responses:
      '200':
        description: |
          List of account''s authorities

          * Returns `hafbe_backend.account_authority`
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/hafbe_backend.account_authority'
            example: {
              "owner": {
                "key_auths": [
                  [
                    "STM7WdrxF6iuSiHUB4maoLGXXBKXbqAJ9AZbzACX1MPK2AkuCh23S",
                    1
                  ]
                ],
                "account_auths": [],
                "weight_threshold": 1
              },
              "active": {
                "key_auths": [
                  [
                    "STM5vgGoHBrUuDCspAPYi3dLwSyistyrz61NWkZNUAXAifZJaDLPF",
                    1
                  ]
                ],
                "account_auths": [],
                "weight_threshold": 1
              },
              "posting": {
                "key_auths": [
                  [
                    "STM5SaNVKJgy6ghnkNoMAprTxSDG55zps21Bo8qe1rnHmwAR4LzzC",
                    1
                  ]
                ],
                "account_auths": [],
                "weight_threshold": 1
              },
              "memo": "STM7EAUbNf1CdTrMbydPoBTRMG4afXCoAErBJYevhgne6zEP6rVBT",
              "witness_signing": "STM4vmVc3rErkueyWNddyGfmjmLs3Rr4i7YJi8Z7gFeWhakXM4nEz"
            }
      '404':
        description: No such account in the database
 */
-- openapi-generated-code-begin
DROP FUNCTION IF EXISTS hafbe_endpoints.get_account_authority;
CREATE OR REPLACE FUNCTION hafbe_endpoints.get_account_authority(
    "account-name" TEXT
)
RETURNS hafbe_backend.account_authority 
-- openapi-generated-code-end
LANGUAGE 'plpgsql'
STABLE
SET JIT = OFF
SET join_collapse_limit = 16
SET from_collapse_limit = 16
AS
$$
BEGIN
    RETURN hafbe_backend.get_account_authority_endpoint("account-name");
END
$$;

RESET ROLE;

SET ROLE hafbe_owner;

-- Metadata types for endpoint information

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.endpoint_parameter:
  type: object
  properties:
    name:
      type: string
      description: parameter name
    in:
      type: string
      description: parameter location (path, query)
    required:
      type: boolean
      description: whether the parameter is required
    type:
      type: string
      description: parameter data type
    default:
      type: string
      x-sql-datatype: JSON
      description: default value
    description:
      type: string
      description: parameter description
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.endpoint_parameter CASCADE;
CREATE TYPE hafbe_backend.endpoint_parameter AS (
    "name" TEXT,
    "in" TEXT,
    "required" BOOLEAN,
    "type" TEXT,
    "default" JSON,
    "description" TEXT
);
-- openapi-generated-code-end

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.endpoint_metadata:
  type: object
  properties:
    path:
      type: string
      description: REST endpoint path
    method:
      type: string
      description: HTTP method (GET, POST, etc.)
    tags:
      type: array
      items:
        type: string
      description: endpoint category tags
    summary:
      type: string
      description: brief endpoint description
    description:
      type: string
      description: detailed endpoint description
    rpc_function:
      type: string
      description: SQL function name (operationId from OpenAPI spec)
    installed:
      type: boolean
      description: >-
        true only when the backing SQL function exists in pg_proc AND
        its parameter names and return type match the OpenAPI declaration
    mismatch_reason:
      type: string
      description: >-
        When installed is false, explains why — e.g.
        "function_not_found", "parameter_mismatch", "return_type_mismatch".
        NULL when installed is true.
    parameters:
      type: array
      items:
        $ref: '#/components/schemas/hafbe_backend.endpoint_parameter'
      description: list of endpoint parameters
    return_type:
      type: string
      description: return data type
    version:
      type: string
      description: HAFBE version
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.endpoint_metadata CASCADE;
CREATE TYPE hafbe_backend.endpoint_metadata AS (
    "path" TEXT,
    "method" TEXT,
    "tags" TEXT[],
    "summary" TEXT,
    "description" TEXT,
    "rpc_function" TEXT,
    "installed" BOOLEAN,
    "mismatch_reason" TEXT,
    "parameters" hafbe_backend.endpoint_parameter[],
    "return_type" TEXT,
    "version" TEXT
);
-- openapi-generated-code-end

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.endpoints_response:
  type: object
  properties:
    version:
      type: string
      description: HAFBE version
    endpoints:
      type: array
      items:
        $ref: '#/components/schemas/hafbe_backend.endpoint_metadata'
      description: list of all endpoints
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.endpoints_response CASCADE;
CREATE TYPE hafbe_backend.endpoints_response AS (
    "version" TEXT,
    "endpoints" hafbe_backend.endpoint_metadata[]
);
-- openapi-generated-code-end

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.consistency_issue:
  type: object
  properties:
    issue_type:
      type: string
      description: |
        Type of inconsistency:
        - `openapi_not_installed` – in OpenAPI spec but DB function missing
        - `installed_not_rewritten` – DB function exists but no rewrite rule
        - `rewritten_not_in_openapi` – rewrite rule exists but missing from OpenAPI
        - `rewrite_target_mismatch` – rewrite points to different function than operationId
        - `type_mismatch` – OpenAPI schema type missing from database
    path:
      type: string
      description: REST path where the issue was found
    rpc_function:
      type: string
      description: SQL function name involved
    details:
      type: string
      description: human-readable explanation
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.consistency_issue CASCADE;
CREATE TYPE hafbe_backend.consistency_issue AS (
    "issue_type" TEXT,
    "path" TEXT,
    "rpc_function" TEXT,
    "details" TEXT
);
-- openapi-generated-code-end

----------------------------------------------------------------------

/** openapi:components:schemas
hafbe_backend.endpoints_consistency_response:
  type: object
  properties:
    version:
      type: string
      description: HAFBE version
    total_endpoints:
      type: integer
      description: total number of endpoints in OpenAPI spec
    installed_count:
      type: integer
      description: number of endpoints properly installed in DB
    rewritten_count:
      type: integer
      description: number of endpoints with rewrite rules
    issues_found:
      type: integer
      description: number of consistency issues found
    issues:
      type: array
      items:
        $ref: '#/components/schemas/hafbe_backend.consistency_issue'
      description: list of consistency issues
 */
-- openapi-generated-code-begin
DROP TYPE IF EXISTS hafbe_backend.endpoints_consistency_response CASCADE;
CREATE TYPE hafbe_backend.endpoints_consistency_response AS (
    "version" TEXT,
    "total_endpoints" INTEGER,
    "installed_count" INTEGER,
    "rewritten_count" INTEGER,
    "issues_found" INTEGER,
    "issues" hafbe_backend.consistency_issue[]
);
-- openapi-generated-code-end

RESET ROLE;

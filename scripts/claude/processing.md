# HAFBE Processing & Synchronization

This document covers how HAFBE processes blockchain data from HAF.

## Overview

HAFBE processes blocks from HAF (Hive Application Framework) via a main loop that runs continuously. The entry point is `hafbe_app.main()` called by `scripts/process_blocks.sh`.

**Processing pipeline:**
1. `scripts/process_blocks.sh` starts the application
2. `hafbe_app.main()` enters an infinite loop calling `hive.app_next_iteration()`
3. For each block range, `log_and_process_blocks()` orchestrates:
   - Balance Tracker processing (btracker)
   - HAFBE core processing (defined in `db/processing_pipeline.sql`)
   - HAF state provider updates

## Unified Pipeline Definition

**The single source of truth for processing order is `db/processing_pipeline.sql`.**

This file defines:
- All processors and their execution order
- Which mode(s) each runs in (MASSIVE / LIVE / BOTH)
- Prerequisite dependencies between processors
- Target tables each processor writes to
- Idempotency guarantees
- Dispatch functions that read the table at runtime

**No need to edit `massive_processing()`, `single_processing()`, or `process_blocks()` when adding a new processor.**
Just insert a row into `hafbe_app.processing_pipeline` and the dispatch functions will pick it up automatically.

### Pipeline Table Columns:

| Column | Purpose |
|--------|---------|
| `processor_id` | Stable unique key (never change after merge) |
| `execution_order` | Run order within each stage (ascending) |
| `processor_name` | Human-readable name |
| `function_schema` / `function_name` | SQL function to call |
| `function_signature` | `(_from INT, _to INT)` for state, `()` for cache |
| `run_in_massive` | TRUE to run during bulk sync |
| `run_in_live` | TRUE to run per block during live sync |
| `prerequisites` | Array of `processor_id` that must complete first |
| `target_tables` | Array of tables written to (for vacuum / docs) |
| `idempotency` | `FULLY`, `RANGE`, or `NONE` |
| `description` | One-line purpose |

### Pipeline Execution Stages:

**Stage 1 (order 10-60): STATE PROCESSORS — run in BOTH modes
- `account_stats` (10) → account creation, recovery, voting rights
- `block_operations` (20) → per-block op counts + per-op-type daily/monthly rollups
- `transaction_stats` (30) → daily/monthly transaction aggregations
- `witness_stats` (40) → witness metadata
- `witness_votes` (50) → witness votes and proxies
- `proposals` (60) → ALL proposal ops (unified row-by-row)

**Stage 2 (order 100-110): CACHE REFRESH — LIVE only**
- `witness_votes_cache` (100) → rebuilds account_vest_stats_cache + witness caches
- `proposal_vote_stats_cache` (110) → stake-weighted proposal vote totals

### Dispatch Functions (in `processing_pipeline.sql`):

| Function | Purpose |
|----------|---------|
| `run_pipeline_massive(_from, _to)` | Runs all state processors for a block range |
| `run_pipeline_live(_block)` | Runs ALL processors for a single block |
| `run_pipeline_cache_seed()` | Seeds caches once at MASSIVE→LIVE transition |
| `get_pipeline_vacuum_tables(_stage)` | Returns target tables for vacuum requests |
| `validate_processing_pipeline(_mode)` | Validates pipeline configuration (auto-runs before dispatch) |

### Pipeline Validation:

The pipeline is **automatically validated** before every execution to catch configuration errors early:

```sql
SELECT hafbe_app.validate_processing_pipeline();      -- Validate both modes
SELECT hafbe_app.validate_processing_pipeline('MASSIVE');
SELECT hafbe_app.validate_processing_pipeline('LIVE');
```

**Checks performed:**
1. **processor_id uniqueness** - No duplicate processor IDs
2. **execution_order uniqueness** - No duplicate execution orders within each mode
3. **Prerequisite validity** - All dependencies exist, run in the same mode, and have earlier execution_order
4. **No circular dependencies** - Detects cycles like A→B→A
5. **Function existence** - All referenced functions exist with matching signatures
6. **Target table validity** - All target_tables exist in hafbe_app schema (no schema prefix)

**When validation runs:**
- **At install time**: `scripts/install_app.sh` calls `validate_processing_pipeline()` after installing all processors
- **At runtime**: `run_pipeline_massive()`, `run_pipeline_live()`, and `run_pipeline_cache_seed()` all call validation before execution

**If validation fails**: Raises a detailed EXCEPTION listing all violations. No data is processed until all issues are fixed.

### Processor File Contract:

Every `db/process_*.sql` file has a `PIPELINE CONTRACT` block in its header that documents:
```
 * ======================= PIPELINE CONTRACT =======================
 * Processor ID    : account_stats
 * Execution Order : 10
 * Runs In         : MASSIVE, LIVE
 * Prerequisites   : (none)
 * Target Tables   : hafbe_app.account_parameters
 * Idempotency     : RANGE
 * Downstream Users: process_proposals
 * =================================================================
```

## Processing Stages

HAFBE uses two synchronization stages defined in `db/hafbe_app.sql`:

### MASSIVE_PROCESSING (Bulk Sync)

- **When**: Initial sync or catching up after downtime
- **Batch size**: 10,000 blocks per iteration
- **Optimization**: `synchronous_commit = OFF` for throughput
- **Behavior**: No cache tables, indexes created after stage completes

### LIVE Mode

- **When**: Caught up with blockchain head
- **Batch size**: 1 block per iteration
- **Optimization**: `synchronous_commit = ON` for data safety
- **Behavior**: Updates cache tables, indexes already exist

**Stage detection:**
```sql
SELECT hive.get_current_stage_name('hafbe_app');  -- Returns 'MASSIVE_PROCESSING' or 'LIVE'
```

## Processing Functions Inventory

All processing functions are in `db/process_*.sql` files.

| Function | File | Purpose |
|----------|------|---------|
| `process_blocks()` | `hafbe_app.sql` | Dispatcher - routes to massive or single processing |
| `massive_processing()` | `hafbe_app.sql` | Processes block ranges during bulk sync |
| `single_processing()` | `hafbe_app.sql` | Processes individual blocks in live mode |
| `process_account_stats()` | `process_account_stats.sql` | Account creation, recovery, voting rights |
| `process_block_operations()` | `process_block_operations.sql` | Op counts per block + daily/monthly per-op-type rollups (single scan, three sinks) |
| `process_transaction_stats()` | `process_transaction_stats.sql` | Daily/monthly transaction aggregations |
| `process_witness_stats()` | `process_witness_stats.sql` | Witness properties and metadata |
| `process_witness_votes()` | `process_witness_votes.sql` | Witness votes and proxy assignments |
| `process_witness_votes_cache()` | `process_witness_votes.sql` | Cache refresh (LIVE only) |
| `process_proposals()` | `process_proposals.sql` | UNIFIED processor for ALL proposal ops — create (paired with virtual proposal_fee for id capture) / update / remove / pay / update_proposal_votes / declined_voting_rights / expired_account. Uses an explicit FOR loop (not CTE+CASE) because operation ordering is safety-critical: remove-then-vote sequences in the same batch must not insert votes after the cascade. `process_proposal_vote_op` only records votes for proposals that currently exist and are not removed — mirroring hived's `update_proposal_votes_evaluator`, which `continue`s past missing/removed proposal_ids. Pre-HF28 the chain accepted (and silently dropped) votes for nonexistent proposals; replaying them without this guard tripped the `current_proposal_votes -> current_proposals` FK and crashed block processing. |
| `process_proposal_vote_stats_cache()` | `process_proposal_vote_stats_cache.sql` | Stake-weighted proposal vote totals (LIVE only; mirrors witness cache pattern, runs after `process_witness_votes_cache` so account_vest_stats_cache is fresh) |

### Processing Order

Each block range calls processors in this order:
1. `process_account_stats()` - Account parameters
2. `process_block_operations()` - Op counts per block + per-day/month per-op-type rollups
3. `process_transaction_stats()` - Transaction aggregations
4. `process_witness_stats()` - Witness metadata
5. `process_witness_votes()` - Vote and proxy state
6. `process_proposals()` - All proposal ops in one row-by-row processor: create/update/remove/pay + update_proposal_votes + decline/expired cleanup

In LIVE mode, two cache refreshes run after the processors (in this order):
- `process_witness_votes_cache()` - rebuilds `account_vest_stats_cache` + witness vote caches
- `process_proposal_vote_stats_cache()` - rebuilds `proposal_vote_stats_cache` (depends on the fresh `account_vest_stats_cache`)

### Why process_proposals uses a FOR LOOP instead of CTE+CASE

Most processors (e.g. `process_witness_votes`) dispatch per-op handlers via a
`WITH ... SELECT CASE` pattern where the planner evaluates the CASE expressions
in ORDER BY id sequence. PostgreSQL does not formally guarantee that
side-effecting functions in a SELECT list fire in ORDER BY order — it works in
practice but is a planner assumption, not a spec guarantee.

For proposal processing the ordering invariant is safety-critical: a
remove-then-vote sequence arriving in the same MASSIVE batch must not insert a
vote row after the remove cascade has already deleted the proposal's votes.
An explicit PL/pgSQL `FOR` loop iterates in the cursor's `ORDER BY id` sequence
by definition, so the guarantee is structural rather than planner-dependent.
`process_witness_votes` keeps the CTE+CASE pattern (accepted assumption already
in production); `process_proposals` uses the loop where the stakes are higher.

## Submodule Processing

HAFBE delegates some processing to integrated submodules:

### Balance Tracker (btracker)
- **Called via**: `btracker_process_blocks()` in `log_and_process_blocks()`
- **Purpose**: Account balances (HIVE, HBD, VESTS, savings, delegations)
- **Schema**: `hafbe_bal`
- **Docs**: `submodules/btracker/scripts/claude/`

### Reputation Tracker (reptracker)
- **Integration**: Separate HAF app with own processing loop
- **Purpose**: Account reputation scores from votes
- **Schema**: `reptracker_app`
- **Docs**: `submodules/reptracker/scripts/claude/`

### HAfAH (hafah)
- **Integration**: Uses HAF state providers, no custom processing
- **Purpose**: Account operation history
- **Docs**: `submodules/hafah/CLAUDE.md` (basic documentation only - no modular docs)

## Control Functions

Located in `db/hafbe_app.sql`:

| Function | Purpose |
|----------|---------|
| `allowProcessing()` | Enable processing (called at startup) |
| `stopProcessing()` | Signal graceful shutdown |
| `continueProcessing()` | Check if should continue (polled in loop) |

**Graceful shutdown:**
```sql
-- From another session:
SELECT hafbe_app.stopProcessing();
COMMIT;  -- Must commit for change to be visible
```

## Detailed Documentation

For implementation details of each processor:

| Processor | Documentation |
|-----------|---------------|
| Account Stats | [processing/accounts.md](processing/accounts.md) |
| Witness Stats | [processing/witnesses.md](processing/witnesses.md) |
| Witness Votes | [processing/witness_votes.md](processing/witness_votes.md) |
| Block Operations | [processing/blocks.md](processing/blocks.md) |
| Transaction Stats | [processing/transactions.md](processing/transactions.md) |

## Key Tables

### Core Processing Tables
| Table | Populated By | Purpose |
|-------|--------------|---------|
| `hafbe_app.account_parameters` | `process_account_stats()` | Account metadata |
| `hafbe_app.block_operations` | `process_block_operations()` | Op counts per block |
| `hafbe_app.transaction_stats_by_day` | `process_transaction_stats()` | Daily tx stats |
| `hafbe_app.transaction_stats_by_month` | `process_transaction_stats()` | Monthly tx stats |
| `hafbe_app.operation_type_stats_by_day` | `process_block_operations()` | Daily per-op-type counts |
| `hafbe_app.operation_type_stats_by_month` | `process_block_operations()` | Monthly per-op-type counts |
| `hafbe_app.current_witnesses` | `process_witness_stats()` | Witness properties |
| `hafbe_app.witness_votes_history` | `process_witness_votes()` | Vote change log |
| `hafbe_app.current_witness_votes` | `process_witness_votes()` | Active votes |
| `hafbe_app.account_proxies_history` | `process_witness_votes()` | Proxy change log |
| `hafbe_app.current_account_proxies` | `process_witness_votes()` | Active proxies |
| `hafbe_app.proposal_votes_history` | `process_proposals()` | Proposal vote change log (includes synthetic `approve=FALSE` rows from remove/decline cascades) |
| `hafbe_app.current_proposal_votes` | `process_proposals()` | Currently active proposal approvals |
| `hafbe_app.current_proposals` | `process_proposals()` | Proposal metadata mirror (create/update/remove); `paid_amount` column is a running total incremented by each `proposal_pay_operation` |
| `hafbe_app.proposal_payments` | `process_proposals()` | Append-only per-payment audit ledger from `proposal_pay_operation` |

### Cache Tables (LIVE only)
| Table | Purpose |
|-------|---------|
| `hafbe_app.account_vest_stats_cache` | Vesting power per account |
| `hafbe_app.witness_votes_cache` | Total votes per witness |
| `hafbe_app.witness_rank_cache` | Witness rankings |
| `hafbe_app.witness_votes_change_cache` | 24h vote changes |
| `hafbe_app.proposal_vote_stats_cache` | Stake-weighted proposal totals + voters_num |

## Expansion Rules

### Adding a New Processor

**Step 1: Insert row into pipeline definition**
Edit `db/processing_pipeline.sql` and add an INSERT statement:
```sql
INSERT INTO hafbe_app.processing_pipeline (
    processor_id, execution_order, processor_name,
    function_schema, function_name, function_signature,
    run_in_massive, run_in_live, prerequisites, target_tables, idempotency, description
) VALUES (
    'my_new_processor', 70, 'process_my_new_processor',
    'hafbe_app', 'process_my_new_processor', '(_from INT, _to INT)',
    TRUE, TRUE, ARRAY['account_stats', 'witness_votes'],
    ARRAY['my_new_table'],
    'RANGE',
    'One-line description of what this does'
) ON CONFLICT DO NOTHING;
```

- Pick an `execution_order` between the last processor you depend on and the next one
- Use `execution_order < 100` for state processors, `>= 100` for cache processors
- `function_signature`: `(_from INT, _to INT)` for state, `()` for cache
- `target_tables`: Use table names WITHOUT schema prefix (all tables are in `hafbe_app` schema)

**Step 2: Create the processor file**
Create `db/process_<name>.sql` with:
- Include the `PIPELINE CONTRACT` block in the header (see existing files for template)
- Function must match the schema/name/signature in the pipeline table
- Add `PIPELINE CONTRACT` header block

**Step 3: Add to install script**
Edit `scripts/install_app.sh`:
- For state processors: add after `process_block_operations.sql` (or after your prerequisites)
- For cache processors: add after `process_proposal_vote_stats_cache.sql`

**Step 4: Document**
- Create documentation at `scripts/claude/processing/<name>.md`
- Update the **Pipeline Execution Stages** list above with a one-liner
- Add any new tables to the **Key Tables** section

**Step 5: Register tables (if needed)**
- In `db/hafbe_app.sql`, add `hive.app_register_table()` calls for new state tables
- Cache tables (LIVE-only) do NOT need HAF registration

### Modifying Existing Processors

1. Update the corresponding `db/process_*.sql` file
2. Update the pipeline row in `db/processing_pipeline.sql` if dependencies/targets changed
3. Update detailed docs in `scripts/claude/processing/`
4. If adding new tables, register with `hive.app_register_table()`

### Querying the Pipeline

To see the current pipeline definition:
```sql
-- All processors in execution order
SELECT processor_id, execution_order, run_in_massive, run_in_live, prerequisites, description
FROM hafbe_app.processing_pipeline
ORDER BY execution_order;

-- Just LIVE cache processors
SELECT processor_id, target_tables
FROM hafbe_app.processing_pipeline
WHERE execution_order >= 100
ORDER BY execution_order;

-- Check vacuum tables for a stage
SELECT * FROM hafbe_app.get_pipeline_vacuum_tables('MASSIVE');

-- Validate pipeline configuration (runs all checks, raises exception on failure)
SELECT hafbe_app.validate_processing_pipeline();

-- Validate a specific mode only
SELECT hafbe_app.validate_processing_pipeline('LIVE');
```

# Remove Pipeline Budget Sync

Status: completed
Created: 2026-02-26
Updated: 2026-02-26

## Goal

Reduce allocation hot-path gas/risk by removing best-effort `BudgetTreasury.sync()` attempts from `GoalFlowAllocationLedgerPipeline`.

## Scope

- In scope:
  - Remove pipeline treasury-sync call path and related events/diagnostic helpers from `GoalFlowAllocationLedgerPipeline`.
  - Update flow pipeline tests that asserted budget treasury sync attempts/diagnostics.
  - Preserve child allocation sync behavior.
- Out of scope:
  - `BudgetTCR.syncBudgetTreasuries` behavior.
  - Changes under `lib/**`.

## Constraints

- Keep allocation commit + child-sync semantics unchanged.
- Keep permissionless budget recovery via `BudgetTCR.syncBudgetTreasuries`.
- Required Solidity verification gate: `pnpm -s verify:required`.

## Acceptance Criteria

- Parent allocation maintenance no longer calls `IBudgetTreasury.sync()` inside the pipeline.
- Child-sync execution and gas-budget skip behavior remain intact.
- Existing budget-sync-in-pipeline tests are removed or updated to match new behavior.

## Verification

- `pnpm -s verify:required` (pass before/after simplify; later rerun failed due unrelated out-of-scope compile errors in active GoalFactory/BudgetTCR worktree files)
- `FOUNDRY_SPARSE_MODE=true forge test -vvv --match-path test/flows/FlowBudgetStakeAutoSync.t.sol --match-test doesNotAttemptBudgetTreasurySync_forChangedBudget` (blocked by same unrelated out-of-scope compile errors on current tree)

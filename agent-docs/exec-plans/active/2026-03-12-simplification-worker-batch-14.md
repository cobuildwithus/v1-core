# 2026-03-12 Simplification Worker Batch 14

Status: completed
Created: 2026-03-12
Updated: 2026-03-13

## Goal

- Land the two still-worthwhile simplifications that are now clear of real code conflicts:
  - target 1: shared spend-policy validation probe helper
  - target 4: derive managed active state instead of storing it twice

## Scope

- `src/goals/TreasuryBase.sol`
- `src/goals/GoalFactory.sol`
- `src/tcr/library/BudgetTCRInitValidation.sol`
- optional shared spend-policy helper library
- `src/goals/ManagedBudgetController.sol`
- `src/interfaces/IManagedBudgetController.sol` only if required to preserve/clarify the same ABI
- targeted tests for those surfaces

## Constraints

- `workspace-docs/bin/codex-workers` runs child Codex sessions in the same live worktree.
- Do not disturb the separate live exit-router lane in `src/juicebox/**`.
- Keep target 1 independent from the larger GoalFactory deployment-plan and stack-composer refactors.
- Keep target 4 independent from the later topology/runtime dedupe work.

## Intended change

1. Extract the common spend-policy validation probe into one helper and keep caller-specific error behavior in:
   - `TreasuryBase`
   - `GoalFactory`
   - `BudgetTCRInitValidation`
2. Remove `ManagedBudgetController.BudgetDeployment.active` when it is strictly derivable from `_activeBudgetIndexPlusOne[itemID] != 0`, preserving external view shapes and inactive/removed semantics.

## Launch Plan

1. Run codex-2 target-1 and target-4 workers in parallel.
2. Review and integrate their diffs.
3. Run required Solidity verification:
   - `pnpm -s verify:required`
   - `pnpm -s lint:solidity:warnings`
   - `pnpm -s build:sizes`
4. Run completion workflow passes:
   - simplify
   - test-coverage-audit
   - task-finish-review

## Notes

- Earlier blocker reasoning was stale because the old open-prune/managed-gate file scopes are now clean in git.
- `COORDINATION_LEDGER.md` was trimmed back to the actually live lanes before launching this batch.
- Landed target 1 with `src/library/SpendPolicyValidationLib.sol` and caller-specific invalid-policy reverts preserved in `TreasuryBase`, `GoalFactory`, and `BudgetTCRInitValidation`.
- Landed target 4 by removing stored managed-budget `active` state and deriving it from `_activeBudgetIndexPlusOne`.
- Completion workflow ran in sequence:
  - simplify: no additional target-1 work; target-4 follow-up reduced `_setItemActive` call-site branching
  - test-coverage-audit: added malformed-sync-mode regression coverage in `test/goals/GoalFactorySpendPolicyDeploy.t.sol`, `test/BudgetTCR.t.sol`, and `test/goals/BudgetTreasury.t.sol`
  - task-finish-review: no high-severity findings; one medium-risk architecture follow-up remains around constraining `ManagedBudgetController` to the managed-preset deployer shape
- Final verification on the post-coverage tree passed:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `pnpm -s build:sizes`

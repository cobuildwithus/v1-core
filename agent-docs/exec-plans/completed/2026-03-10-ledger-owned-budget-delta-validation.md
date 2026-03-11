# Ledger-Owned Budget Delta Validation

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Make budget allocation delta detection owned by `BudgetStakeLedger`, preserve current downstream ordering semantics, and fail closed locally on malformed recipient ordering instead of relying on upstream sorting conventions.

## Scope

- In scope:
  - Move changed-budget detection into `BudgetStakeLedger` for commit and preview use.
  - Remove the pipeline hot-path dependency on `GoalFlowLedgerMode.detectBudgetDeltasCalldata(...)`.
  - Add local malformed-order enforcement in the merge/checkpoint path without adding a redundant full validation pre-pass.
  - Update focused tests around parity, ledger invariants, and pipeline/preview behavior.
- Out of scope:
  - Behavior changes to premium accrual, child-sync debt policy, or allocation commit validation in `FlowAllocations`.
  - Changes under `lib/**`.

## Constraints

- Preserve current changed-budget output ordering: decreases first, then increases, stable within each bucket.
- Preserve fail-closed accounting semantics for premium-checkpoint critical paths.
- Keep preview semantics aligned with commit semantics for changed-budget detection.
- Run required Solidity verification before handoff:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`

## Acceptance Criteria

- `BudgetStakeLedger` locally rejects malformed recipient ordering on checkpoint/delta paths.
- The pipeline consumes ledger-owned changed-budget detection instead of re-deriving deltas itself.
- Preview uses the same ledger diff logic as commit.
- Existing decreases-before-increases behavior remains covered by tests.
- Required verification passes, or any blocker is confirmed unrelated and documented.

## Progress Log

- 2026-03-10: Plan created. Scoped ledger-owned delta detection, single-pass local order enforcement, and parity/regression coverage.
- 2026-03-10: Updated `IBudgetStakeLedger` so checkpointing returns changed budgets and added `previewChangedBudgetTreasuries(...)` for the read path.
- 2026-03-10: Rewired `GoalFlowAllocationLedgerPipeline` to consume ledger-owned changed-budget detection on both commit and preview paths; removed the duplicate merge/delta path from `GoalFlowLedgerMode`.
- 2026-03-10: Added real-ledger regression tests for malformed ordering and preview/commit ordering parity; updated parity/property harnesses and fakes for the new ledger API.
- 2026-03-10: Simplify pass inlined the single-use pipeline checkpoint helper and removed the obsolete `DetectParams.allocationScalePpm` test-only field.
- 2026-03-10: Coverage audit added a fuzz regression asserting `previewChangedBudgetTreasuries(...)` matches `checkpointAllocation(...)` returned deltas across randomized sorted inputs.
- 2026-03-10: Re-ran required gates after simplify/coverage changes. `pnpm -s verify:required` is currently blocked by an unrelated duplicate test name in `test/goals/PremiumEscrow.t.sol`; `pnpm -s lint:solidity:warnings` is also blocked by the same global compile failure before the warning baseline completes. Focused flow/ledger suites passed when that unrelated file was skipped.
- 2026-03-10: Fixed the remaining refactor-induced `GoalFlowLedgerModeHarness.DetectParams` constructor mismatch in `test/flows/GoalFlowLedgerModeBranchCoverage.t.sol`.
- 2026-03-10: Task-finish review subagent reported no findings on the core production surface; residual risk is limited to broader caller/ABI coverage for the new `IBudgetStakeLedger` return/preview methods outside this change set.
- 2026-03-10: Final repo-wide verification passed after shared-worktree cleanup via `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

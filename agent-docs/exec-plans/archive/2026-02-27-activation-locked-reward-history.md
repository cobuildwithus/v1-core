# 2026-02-27 activation-locked-reward-history

Status: in_progress
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Apply a hard cutover so accepted budget removals preserve reward-history eligibility once a budget has crossed the activation lock, while still stopping forward funding and spend immediately.

## Scope

- In scope:
  - `IBudgetStakeLedger` removal API cutover (`removeBudget` derived lock return).
  - `BudgetStakeLedger` tracking/finalization semantics for removed budgets under activation lock.
  - `BudgetTCR.finalizeRemovedBudget` / `retryRemovedBudgetResolution` branch split:
    - pre-lock removal keeps disable+terminalize fail-closed behavior,
    - post-lock removal stops forward funding/spend without retroactive success-invalidation.
  - Tests/mocks/docs directly affected by those semantics.
- Out of scope:
  - `NoWinners` terminal mode changes.
  - new sink/burn policy redesigns.
  - any `lib/**` edits.

## Constraints

- Hard cutover (no backward-compatibility interface shim path).
- Keep direct post-removal donations allowed.
- Removed post-lock budgets remain success-eligible only if they later resolve `Succeeded`.
- Fail closed when required forward spend-stop calls fail.

## Design

1. Replace `removeBudget(bytes32)` with `removeBudget(bytes32) returns (bool lockRewardHistory)` and derive lock status from budget facts inside ledger.
2. In ledger:
   - always set `removedAt`,
   - keep removed budget in tracked set when lock is true,
   - prune removed budget from tracked set when lock is false.
3. Keep points cutoff at removal time in both branches.
4. Update success finalization/readiness:
   - removed+unlocked budgets do not block readiness and remain success-ineligible,
   - removed+locked budgets block readiness until resolved and remain success-eligible if terminal state is `Succeeded`.
5. In `BudgetTCR.finalizeRemovedBudget`:
   - remove from parent + ledger always,
   - unlocked branch: disable success resolution + strict terminalization,
   - locked branch: force outflow to zero only (no disable, no forced failure).
6. In `retryRemovedBudgetResolution`:
   - preserve existing pre-lock terminalization retry behavior,
   - for locked branch, only re-enforce forward spend stop and report resolved status.

## Verification Plan

- Targeted `forge test` for touched suites:
  - `test/BudgetTCR.t.sol`
  - `test/goals/BudgetStakeLedgerRegistration.t.sol`
  - `test/goals/BudgetStakeLedgerEconomics.t.sol`
  - `test/goals/BudgetStakeLedgerPagination.t.sol`
  - `test/goals/BudgetStakeLedgerBranchCoverage.t.sol`
  - `test/goals/RewardEscrow.t.sol`
  - `test/goals/RewardEscrowPagination.t.sol`
  - `test/goals/RewardEscrowDustRetention.t.sol`
- Required gate: `pnpm -s verify:required`.
- Completion workflow passes:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

## Pass Notes

- 2026-02-27 (`simplify`):
  - flattened a pure readiness predicate in `BudgetStakeLedger` (`_isBudgetReadyForSuccessFinalization`) to a single boolean expression;
  - removed duplicate emit/early-return branching in `BudgetTCR.retryRemovedBudgetResolution` while preserving branch semantics;
  - extracted duplicated mock lock-derivation control flow in `MockBudgetStakeLedgerForBudgetTCR` into a private helper.
- 2026-02-27 (`test-coverage-audit`):
  - added `test_removeBudget_activationLockedBudgetFailedResolutionStillCountsAsResolved` in `test/goals/BudgetStakeLedgerRegistration.t.sol` to assert post-lock removals unblock readiness when later resolved `Failed`;
  - added `test_finalize_success_removedActivationLockedBudget_failedResolutionUnblocksAndExcludesSuccess` in `test/goals/BudgetStakeLedgerPagination.t.sol` to ensure finalize pagination resumes after locked removal resolves `Failed` and excludes success attribution;
  - added `test_finalize_success_removedActivationLockedBudgetResolvedFailed_capsPointsAtRemoval_andExcludesRewards` in `test/goals/RewardEscrow.t.sol` to verify reward-history lock does not grant rewards when final budget state is `Failed`;
  - added `test_retryRemovedBudgetResolution_revertsWhenForceZeroingFails_forActivationLockedRemoval` in `test/BudgetTCR.t.sol` to enforce fail-closed retry semantics when forward spend-stop cannot be re-applied;
  - ran: `forge test --match-path test/goals/BudgetStakeLedgerRegistration.t.sol`, `forge test --match-path test/goals/BudgetStakeLedgerPagination.t.sol`, `forge test --match-path test/goals/RewardEscrow.t.sol`, `forge test --match-path test/BudgetTCR.t.sol` (all passed).

## Open Risks

- Active shared worktree contains unrelated in-flight entries; changes must remain strictly scoped to removal/reward-history semantics.

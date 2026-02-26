# 2026-02-25 success-finalization-precheck-removal

Status: completed
Created: 2026-02-25
Updated: 2026-02-25

## Goal

- Remove the O(n) tracked-budget pre-scan from goal success escrow finalization so very large tracked-budget sets do not block success-side terminal progression due to precheck gas.

## Scope

- In scope:
  - `GoalTreasury` success terminal side-effect path (`_tryFinalizeRewardEscrow`).
  - `BudgetStakeLedger` success-finalization progression behavior for unresolved tracked budgets.
  - `RewardEscrow` success-finalization tests impacted by new unresolved-budget gating semantics.
  - Regression coverage proving success finalization path no longer depends on `allTrackedBudgetsResolved` pre-scan call.
  - Economic risk doc update to mark the specific pre-scan gas blocker as mitigated by design change.
- Out of scope:
  - Redesign of escrow/ledger finalization internals.
  - Interface removal of `allTrackedBudgetsResolved`.
  - Changes to budget settlement semantics.

## Constraints

- Keep lifecycle safety invariant: success remains state-first and non-bricking.
- Keep reward inclusion correctness: unresolved budgets are still handled by escrow/ledger finalization state machine.
- Do not touch `lib/**`.

## Design

1. In `GoalTreasury._tryFinalizeRewardEscrow`, remove success-path `allTrackedBudgetsResolved()` precheck.
2. Ensure `BudgetStakeLedger` success finalization stalls at first unresolved tracked budget (`processed=0`) so unresolved budgets cannot be silently excluded.
3. Call `escrow.finalize(...)` directly for success; escrow/ledger pagination remains the readiness/progression gate.
4. Emit `SuccessRewardsFinalized` only when escrow reports `finalized() == true` after finalize attempt.
5. Add regressions for:
   - no precheck call on `resolveSuccess` and `sync` success paths,
   - stall/resume behavior (including removed-budget edge case),
   - deferred-success event emitted only once completion occurs.
6. Update affected `RewardEscrow` success tests to satisfy new all-tracked-resolved requirement before expecting finalized/claimable outcomes.
7. Update economic considerations note to reflect precheck removal and remaining residual risks.

## Verification Plan

- `pnpm -s verify:required`
- Completion workflow subagent passes:
  - simplify
  - test-coverage-audit
  - task-finish-review

## Outcome

- Implemented all scoped code/test/doc changes.
- Targeted verification:
  - `forge test --match-path test/goals/BudgetStakeLedgerPagination.t.sol` ✅
  - `forge test --match-path test/goals/GoalTreasury.t.sol --match-test "test_(resolveSuccess|sync_success|retryTerminalSideEffects).*"` ✅
  - `forge test --match-path test/goals/RewardEscrow.t.sol` ✅
- Required gate:
  - `pnpm -s verify:required` ❌ with 6 failures outside this task scope:
    - `test/BudgetTCRFlowRemovalLiveness.t.sol` (4 failures)
    - `test/flows/FlowAllocationsLifecycle.t.sol` (2 failures)

## Risks

- Behavior shifts from pre-scan defer to direct finalize attempt; if escrow finalize reverts for non-readiness it is still best-effort and terminal-side-effect-retryable, but event surface around failures can change.

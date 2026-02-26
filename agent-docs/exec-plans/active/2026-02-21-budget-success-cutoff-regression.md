# Budget Success Cutoff Regression Guard

## Goal
Reinstate explicit reward-eligibility cutoff semantics so budgets are counted as successful only when resolved and succeeded by the frozen goal finalization timestamp, and add a regression test proving delayed finalization cannot include late-resolved budgets.

## Scope
- `src/goals/BudgetStakeLedger.sol`: enforce `resolvedAt <= goalFinalizedAt` in success classification helper.
- `test/goals/RewardEscrow.t.sol`: add delayed-finalize regression test with explicit frozen timestamp.

## Invariants to Preserve
- Current immediate finalize flow remains unchanged.
- UMA Policy C timing remains supported (assertion initiated pre-deadline, success may resolve later).
- Reward eligibility snapshot remains anchored to `successAt` cutoff semantics.

## Validation
- `forge build -q`
- `forge test --match-path test/goals/RewardEscrow.t.sol --match-test test_finalize_success_delayedFinalizeExcludesBudgetResolvedAfterFrozenGoalFinalizedAt`
- `pnpm -s test:lite`

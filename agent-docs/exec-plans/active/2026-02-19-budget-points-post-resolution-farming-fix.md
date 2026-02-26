# Budget Points Post-Resolution Farming Fix

## Objective
- Prevent `BudgetStakeLedger` stake-time points from accruing after a budget has already resolved.
- Add regression tests that demonstrate the post-resolution farming vector and verify capped accrual.

## Scope
- `src/goals/BudgetStakeLedger.sol`
- `test/goals/RewardEscrow.t.sol`

## Design Notes
- Keep checkpoint accrual monotonic while clamping accrual time to `min(block.timestamp, resolvedAt)` when a budget has resolved.
- Ensure checkpoint timestamps for both budget and user accrual do not advance past `resolvedAt`.
- Preserve existing finalize snapshot semantics (`min(goalFinalizedAt, resolvedAt)`), now guaranteed by checkpoint-time clamping.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

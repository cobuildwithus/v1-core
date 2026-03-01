# Pre-finalize User Points Preview

## Goal
Ensure `BudgetStakeLedger.userPointsOnBudget` returns a live preview before goal finalization (projected to current time), while preserving existing score cutoff clamps (`fundingDeadline` and budget removal timestamp).

## Scope
- `src/goals/BudgetStakeLedger.sol`: adjust user preview cutoff selection pre-finalize.
- `test/goals/BudgetStakeLedgerEconomics.t.sol`: add regressions for live pre-finalize accrual and clamp behavior.

## Invariants to Preserve
- Finalization snapshot math and claim semantics remain unchanged.
- Pre-finalize preview must still cap at `min(now, budgetScoreEnd, budgetRemovedAt)`.
- Post-finalize behavior remains frozen at `goalFinalizedAt`.

## Validation
- `forge build -q`
- `forge test --match-path test/goals/BudgetStakeLedgerEconomics.t.sol`
- `pnpm -s test:lite`

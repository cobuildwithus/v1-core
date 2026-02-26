# UMA Pending-Assertion Sync Liveness

## Objective
- Prevent pending UMA success assertions from freezing treasury `sync()` flow-rate updates.
- Preserve Policy C semantics: pending assertions still block active-state failure/expiry terminalization races.
- Add regression tests proving flow halts at deadline even when assertion settlement is still pending.

## Scope
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `test/goals/GoalTreasury.t.sol`
- `test/goals/BudgetTreasury.t.sol`

## Design Notes
- In active state, `sync()` should always run `_syncFlowRate()` regardless of pending assertions.
- Keep terminalization guarded:
  - if no pending assertion and deadline reached -> finalize `Expired`,
  - if pending assertion -> no terminal state transition.
- Do not change resolver callback model; settlement/finalization remains decoupled from callback to avoid callback-caused settlement reverts.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

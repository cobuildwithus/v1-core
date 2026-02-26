# Treasury Flow Invariant Split (Goal Spend-Down, Budget Pass-Through)

## Objective
- Resolve treasury flow-rate invariant conflict in issue `#4`.
- Preserve donation ingress for both goal and budget treasuries.
- Make goal treasury spend-down independent of inflow-derived max-safe caps.
- Make budget treasury flow targeting explicitly inflow-driven/pass-through.

## Scope
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `test/goals/GoalTreasury.t.sol`
- `test/goals/BudgetTreasury.t.sol`
- `test/BudgetTCR.t.sol` (if affected by budget pass-through activation semantics)
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/cobuild-protocol-architecture.md`

## Plan
1. Change `GoalTreasury._syncFlowRate` to apply target directly (no inflow cap clamp).
2. Change `BudgetTreasury.targetFlowRate` to use measured incoming flow only in `Active` state.
3. Update tests to match new goal/budget invariants.
4. Update architecture docs to codify the split invariant.
5. Run `forge build -q` and `pnpm -s test:lite`.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

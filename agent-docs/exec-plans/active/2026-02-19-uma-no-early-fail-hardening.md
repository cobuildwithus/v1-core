# Goal

Implement treasury and allocation hardening for UMA-driven resolution:
- prevent early failure finalization in goal/budget treasuries,
- support post-finalization late residual settlement in goal treasury,
- enforce safe witness semantics for first-use allocation keys without adding onchain sorting.

# Scope

- `src/interfaces/IGoalTreasury.sol`
- `src/interfaces/IBudgetTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/library/FlowAllocations.sol`
- `test/goals/GoalTreasury.t.sol`
- `test/goals/BudgetTreasury.t.sol`
- `test/flows/FlowAllocationsWitness.t.sol`
- docs impacted by external interface/behavior changes

# Constraints

- Do not modify `lib/**`.
- Preserve no-sort gas posture: validate sorted input invariants, do not sort in-contract.
- Keep success path deadline semantics intact (`resolveSuccess` before deadline).
- Keep terminal state transitions monotonic and explicit.

# Acceptance criteria

- `resolveFailure` for goal and budget reverts before deadline/funding window end.
- Goal treasury exposes a post-finalization residual settlement path that can burn/split according to final state policy.
- First-use allocation key cannot pass arbitrary non-empty previous witness data into budget checkpointing.
- Regression tests cover new failure gating, late residual settlement, and first-key witness strictness.
- `forge build -q` and `pnpm -s test:lite` pass.

# Progress log

- 2026-02-19: Plan opened; validated current behavior and risk points with subagents + local source/test inspection.

# Open risks

- Interface additions require downstream callers/tooling updates.
- If UMA adapter assumptions drift, onchain failure-gating remains the primary guardrail.

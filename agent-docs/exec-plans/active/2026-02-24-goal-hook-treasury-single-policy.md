# Goal Hook Treasury Single Policy

## Goal
Centralize reserved-split hook routing policy and fallback action in `GoalTreasury` so `GoalRevnetSplitHook` becomes a thin context-validation adapter.

## Scope
- `src/interfaces/IGoalTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `test/goals/GoalRevnetSplitHook.t.sol`
- `test/goals/GoalRevnetIntegration.t.sol`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `ARCHITECTURE.md`

## Constraints
- No changes under `lib/**`.
- Preserve existing funding-open behavior and success-settlement math.
- Remove hook-level lifecycle branching and duplicate fallback policy logic.
- For closed-but-nonterminal windows, avoid irreversible burn; defer until terminal state is known.

## Plan
1. Add a treasury hook-split processor API returning a compact action/result tuple.
2. Implement action selection and execution in `GoalTreasury`:
   - funding-open -> fund flow + record.
   - succeeded+minting-open -> success settlement split.
   - terminal closed -> terminal settlement policy.
   - closed nonterminal -> defer funds (no irreversible action).
3. Settle deferred funds on terminalization and late-residual entrypoint.
4. Refactor hook to: validate context, transfer tokens to treasury, call treasury processor, emit compatibility events.
5. Update tests/docs and verify.

## Risks
- Behavior change in previously reverting closed windows.
- Burn/reward authority must remain correct when actions move from hook to treasury.

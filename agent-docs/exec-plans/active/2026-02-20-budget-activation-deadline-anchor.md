# 2026-02-20 budget-activation-deadline-anchor

## Goal
Eliminate the economic/gameability bug where permissionless early activation can set a budget `deadline` before `fundingDeadline`, making `resolveSuccess()` impossible.

## Scope
- `src/goals/BudgetTreasury.sol`
- `test/goals/BudgetTreasury.t.sol`
- any directly-related docs/tests required to reflect intended deadline semantics

## Constraints
- Do not modify `lib/**`.
- Preserve permissionless liveness (`sync()` remains permissionless).
- Keep success gating on funding window (`resolveSuccess()` still requires funding window ended).
- Ensure no behavior introduces backward-compatibility scaffolding (no live deployments yet).

## Acceptance criteria
- Activation sets `deadline` so a non-empty success window exists whenever execution duration is non-zero.
- The specific impossible-success configuration (early activation with short execution duration) is prevented by construction.
- Existing budget treasury behavior remains consistent except for corrected deadline anchoring.
- Tests cover the regression and pass.

## Progress log
- 2026-02-20: Verified exploit condition in `BudgetTreasury` (`deadline = now + executionDuration`) and reward impact path via `BudgetStakeLedger`/`RewardEscrow`.
- 2026-02-20: Implemented fix by anchoring activation deadline to `fundingDeadline + executionDuration`.
- 2026-02-20: Updated BudgetTreasury tests for new deadline semantics and added exploit regression coverage.
- 2026-02-20: Verification completed: `forge build -q`, targeted forge tests, and `pnpm -s test:lite` all passing.

## Open risks
- Changing deadline anchoring can alter expected flow-rate trajectories for early-activated budgets; test baselines relying on old `activation + executionDuration` semantics must be updated.

# Goal

Require an initialized goal-treasury spend policy on new goal deployments and let `GoalFactory.deployGoal(...)` callers choose that policy at deployment time.

## Scope

- `src/goals/GoalFactory.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/policies/*.sol`
- `src/goals/library/GoalFactoryCoreStackDeploy.sol`
- GoalFactory tests, spend-policy tests, direct goal/invariant setups, and any compile-bound deploy-script mocks that construct `GoalFactory.DeployParams`
- Matching docs only if the public deployment surface changes materially

## Constraints

- No `lib/**` edits.
- Keep unrelated dirty deploy artifact files untouched.
- Do not preserve the goal-treasury zero-policy legacy path; there are no live deployments yet.
- Leave budget-TCR deployment behavior unchanged unless a compile/test call site requires adjustment.
- Run required Solidity verification and completion workflow before handoff.

## Acceptance Criteria

- `GoalFactory.DeployParams` exposes goal spend-policy selection for callers.
- `GoalFactoryCoreStackDeploy` forwards the selected policy into `IGoalTreasury.GoalConfig`.
- `GoalTreasury` rejects missing or uninitialized spend policies and no longer falls back to the built-in legacy formula.
- Spend-policy tests cover initialized vs uninitialized policy instances.
- GoalFactory tests cover forwarding of a nonzero spend-policy address and invalid policy regression cases, and direct goal/invariant setups are updated to supply a real policy.
- Required Solidity verification passes.
Status: completed
Updated: 2026-03-09
Completed: 2026-03-09

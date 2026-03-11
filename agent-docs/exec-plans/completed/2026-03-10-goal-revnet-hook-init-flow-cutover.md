# Goal Revnet Hook Init Flow Cutover

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Remove the redundant `IFlow flow_` initializer parameter from `GoalRevnetSplitHook` and derive the hook's
flow/super-token state from `goalTreasury` instead.

## Scope

- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/library/GoalFactoryCoreStackDeploy.sol`
- Targeted goal-hook and factory wiring tests/mocks

## Constraints

- Preserve hook controller gating, split-group validation, and source-token validation behavior.
- Keep the change as a hard cutover with no compatibility overload for the old initializer shape.
- Run required Solidity verification and completion workflow passes before handoff.

## Acceptance Criteria

- `GoalRevnetSplitHook.initialize` accepts only `(directory, goalTreasury, goalRevnetId)`.
- The hook derives `underlyingToken` from the treasury-owned flow/super token without taking a separate `flow` arg.
- Factory wiring and targeted tests use the new initializer shape.
- Required verification passes after the cutover.

## Progress Log

- 2026-03-10: Confirmed the hook only used `flow_` for contract validation and `superToken().getUnderlyingToken()`, while the treasury already exposes both `flow()` and `superToken()`.
- 2026-03-10: Removed the redundant `flow` initializer arg from `GoalRevnetSplitHook`, derived `underlyingToken` from `goalTreasury.superToken()`, and updated `GoalFactoryCoreStackDeploy` plus targeted tests/mocks to the new initializer shape.
- 2026-03-10: Added regression coverage for treasury-derived super-token init validation and for split-hook factory wiring/order dependencies in `test/hooks/GoalRevnetSplitHook.t.sol` and `test/goals/GoalFactoryCoreStackDeploy.t.sol`.
- 2026-03-10: `forge test --match-path test/hooks/GoalRevnetSplitHook.t.sol` passed before later unrelated workspace compile breakage in concurrent single-strategy work.
- 2026-03-10: Final repo-wide verification passed after shared-worktree cleanup via `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

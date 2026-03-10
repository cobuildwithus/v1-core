# GoalTreasury Owner Event Cleanup

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Remove the stale `owner` field from `IGoalTreasury.GoalConfigured` and delete the matching `initialOwner`
initializer parameter from `GoalTreasury`, since current runtime authority does not use it and the factory path
currently passes a non-owner address into that slot.

## Scope

- `src/interfaces/IGoalTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/library/GoalFactoryCoreStackDeploy.sol`
- Targeted goal treasury tests/mocks expecting the old init/event shape

## Constraints

- Preserve all goal treasury runtime authority, lifecycle, and funds-routing behavior.
- Keep the cleanup hard-cutover with no compatibility shim for the old event/init ABI.
- Run required Solidity verification and completion workflow passes before handoff.

## Acceptance Criteria

- `GoalConfigured` no longer emits an `owner` field.
- `GoalTreasury.initialize` accepts only `GoalConfig`.
- Factory wiring and targeted tests use the new initializer shape.
- Required verification passes after the cleanup.

## Progress Log

- 2026-03-10: Confirmed `initialOwner` is only zero-checked then emitted, with no runtime storage or authority use.
- 2026-03-10: Confirmed `GoalFactoryCoreStackDeploy` currently passes `budgetTcrFactory` into the stale owner slot.
- 2026-03-10: Removed the stale owner field from `IGoalTreasury.GoalConfigured` and collapsed `GoalTreasury.initialize` to a single `GoalConfig` argument; updated factory wiring and affected tests.
- 2026-03-10: Simplify pass tightened `GoalTreasury._initialize(GoalConfig)` visibility to `private` and refreshed the goal treasury event test naming.
- 2026-03-10: Verification passed via `pnpm -s verify:required`, `pnpm -s lint:solidity:warnings`, and `forge test --match-path test/invariant/TreasuryTerminalLifecycle.invariant.t.sol`.
- 2026-03-10: Completion workflow audits found no remaining correctness or coverage issues requiring changes.

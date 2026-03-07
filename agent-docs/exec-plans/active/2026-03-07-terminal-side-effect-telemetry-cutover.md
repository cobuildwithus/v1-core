# 2026-03-07 Terminal Side-Effect Telemetry Cutover

## Goal

Replace the shared treasury `TerminalSideEffectFailed(uint8 operation, bytes reason)` abstraction with explicit, self-describing terminal side-effect telemetry that matches each treasury's actual responsibilities.

## Scope

- `src/interfaces/IGoalTreasury.sol`
- `src/interfaces/IBudgetTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- Treasury regression tests under `test/goals/**`
- Relevant observability docs if the emitted-event surface or rationale needs documentation updates

## Constraints

- Preserve terminal-state transition semantics and permissionless retry behavior.
- Keep best-effort side effects best-effort; this is an observability simplification, not a behavior change.
- Reserve revert-data payloads for actual caught revert bytes only.
- Do not encode synthetic status markers into revert-data fields.

## Planned Changes

1. Replace the shared opcode event declarations in both treasury interfaces with dedicated, named terminal side-effect failure events.
2. Emit the new dedicated events directly at each failure site in `GoalTreasury` and `BudgetTreasury`.
3. Split the budget prune `goalSynced == false` path into a dedicated non-revert event instead of synthetic bytes payloads.
4. Update treasury tests to assert the new event surface and preserve current best-effort behavior.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Targeted Forge treasury tests during iteration as needed

## Risks

- Event-surface changes can break tests or downstream monitoring assumptions if any code still keys on the removed signature.
- The budget prune path has two distinct outcomes (revert vs non-applied goal sync); those must remain distinguishable after simplification.

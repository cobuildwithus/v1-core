# 2026-03-02 Silent Catch Observability

## Goal

Remove silent `catch {}` anti-patterns in Flow + treasury paths by making best-effort failures observable without reducing liveness.

## Scope

- `src/Flow.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/interfaces/IGoalTreasury.sol`
- Regression coverage in:
  - `test/flows/FlowRecipients.t.sol`
  - `test/goals/BudgetTreasury.t.sol`
  - `test/goals/UnderwritingIntegration.t.sol`

## Plan

1. Replace silent Flow outflow refresh catch with reason-aware `TargetOutflowRefreshFailed` emission.
2. Reuse treasury `TerminalSideEffectFailed` telemetry with a new assertion-finalize operation code in both treasuries.
3. Replace GoalTreasury directory-resolution silent catch with structured diagnostic failure reasons surfaced via explicit revert path.
4. Add/extend tests to assert the new events/errors and preserve best-effort state/liveness behavior.
5. Run required Solidity verification and completion workflow passes before handoff.


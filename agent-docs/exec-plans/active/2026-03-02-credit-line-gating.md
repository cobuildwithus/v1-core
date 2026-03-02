# 2026-03-02 Credit-Line Gating

## Goal

Implement budget credit-line enforcement using goal-flow cumulative received exposure as the meter and recipient enable/disable gating in Flow.

## Why

- Move from coverage-speed-limit semantics to credit-line eligibility semantics.
- Keep enforcement deterministic and permissionless via existing `syncBudgetTreasuries` upkeep flow.
- Preserve allocation intent while forcing disabled recipients to effective pool units `0`.

## Scope

- `src/storage/FlowStorage.sol`
- `src/library/FlowRecipients.sol`
- `src/library/FlowAllocations.sol`
- `src/interfaces/IFlow.sol`
- `src/Flow.sol`
- `src/tcr/BudgetTCR.sol`
- `src/goals/GoalTreasury.sol`
- doc/spec updates if behavior contracts changed

## Planned Symbol Changes

- Add recipient-level enabled/disabled state and saved virtual-unit tracking in Flow storage/runtime.
- Add goal-flow recipient gating API (`setRecipientEnabled`) to `IFlow`/`Flow`.
- Update allocation application path so disabled recipients retain virtual units but publish zero pool units.
- Add BudgetTCR credit-line gating calculation and recipient enable toggles in `syncBudgetTreasuries`.
- Remove GoalTreasury coverage-derived outflow-rate clamp (retain empty-pool guard).

## Invariants To Preserve

- Flow allocation commitments and recipient allocation storage remain deterministic.
- Disabled recipient pool units are always zero while preserving virtual allocation state.
- Re-enabling recipient restores saved virtual units.
- `syncBudgetTreasuries` remains best-effort across item batch and does not brick on individual sync failures.
- Goal treasury still returns zero target outflow rate when distribution pool has zero units.

## Verification

- Required gate: `pnpm -s verify:required` (mandatory, `.sol` touched).
- Completion workflow subagent passes:
  - simplify
  - test-coverage-audit
  - task-finish-review

## Notes

- No `lib/**` edits.
- Keep backward-compatibility shims out unless explicitly required.

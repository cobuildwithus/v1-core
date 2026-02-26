# Target Unavailable Fail-Closed

## Goal
Make unresolved budget-child sync target resolution (`TARGET_UNAVAILABLE`) fail-closed on changed budget deltas.

## Scope
- `src/library/GoalFlowLedgerMode.sol`
- `test/flows/FlowBudgetStakeAutoSync.t.sol`

## Constraints
- Do not modify `lib/**`.
- Preserve strict revert semantics for downstream child sync execution failures.
- Keep `NO_COMMITMENT` behavior unchanged.

## Acceptance criteria
- Parent allocation/sync paths revert when a changed budget cannot resolve child sync target.
- `previewChildSyncRequirements` reverts for the same unresolved changed-budget condition.
- Existing skip behavior for `NO_COMMITMENT` remains intact.
- Verification passes:
  - `pnpm -s verify:required`

## Progress log
- 2026-02-23: Plan created.

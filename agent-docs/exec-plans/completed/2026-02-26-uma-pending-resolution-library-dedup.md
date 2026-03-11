# UMA Pending Resolution Library Dedup

Status: completed
Created: 2026-02-26
Updated: 2026-02-26

## Goal

- Remove duplicated UMA pending-assertion post-deadline resolution logic from `GoalTreasury` and `BudgetTreasury`.
- Keep resolver policy and budget reassert-grace behavior unchanged.

## Success criteria

- A shared library owns the duplicated pending-resolution + truthfulness checks.
- `GoalTreasury` and `BudgetTreasury` both call the shared helper.
- Budget-only policy knobs (reassert grace, disable-success policy) remain local to `BudgetTreasury`.
- Required verification passes (`pnpm -s verify:required`).
- Mandatory completion workflow passes run (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Scope

- In scope:
  - `src/goals/library/TreasuryUmaAssertionResolution.sol` (new)
  - `src/goals/GoalTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - Test updates only if coverage audit identifies a gap
- Out of scope:
  - Lifecycle policy changes
  - Resolver ABI/interface changes
  - Any `lib/**` edits

## Risks and mitigations

1. Risk: fail-closed behavior drift during extraction.
   Mitigation: copy existing logic exactly into shared library and preserve current call ordering.
2. Risk: budget post-deadline/reassert branch behavior changes.
   Mitigation: keep `_tryFinalizePostDeadline`, `_tryActivateReassertGrace`, and related policy branches in `BudgetTreasury`.
3. Risk: interface/event regressions.
   Mitigation: avoid external ABI changes and keep emitted events unchanged.

## Verification plan

- `pnpm -s verify:required`
- Completion workflow subagent passes:
  - simplify
  - test-coverage-audit
  - task-finish-review
- Re-run `pnpm -s verify:required` after audit-driven edits.

## Outcome

- Added shared `src/goals/library/TreasuryUmaAssertionResolution.sol` and routed both treasuries through it for pending assertion resolution + truth checks.
- Preserved treasury-specific policy:
  - goal: deadline-path finalize behavior unchanged,
  - budget: reassert grace activation/consumption logic unchanged.
- Completion workflow run:
  - simplify pass: no additional safe simplifications identified,
  - coverage audit: added budget regression test for oracle assertion-read revert fail-closed behavior,
  - completion audit: no findings in scoped review.
- Verification:
  - `pnpm -s verify:required` passed (multiple receipts during this turn, including final post-audit pass).

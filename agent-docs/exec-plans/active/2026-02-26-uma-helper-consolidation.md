# UMA Helper Consolidation

Status: completed
Created: 2026-02-26
Updated: 2026-02-26

## Goal

- Reduce UMA helper sprawl by consolidating treasury-side assertion helpers into one library surface.
- Preserve current strict resolver-path checks and fail-closed sync-path behavior.

## Success criteria

- Goal and Budget treasuries depend on one treasury-side UMA helper library for:
  - pending assertion state/guards,
  - strict truth verification for resolver-driven success resolution,
  - fail-closed post-deadline pending assertion resolution checks.
- Duplicate matcher logic is removed.
- Resolver orchestration contract remains separate.
- Required verification and completion workflow pass.

## Scope

- In scope:
  - `src/goals/library/TreasurySuccessAssertions.sol`
  - `src/goals/library/UMASuccessAssertions.sol` (delete if unused)
  - `src/goals/library/TreasuryUmaAssertionResolution.sol` (delete if unused)
  - `src/goals/GoalTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - tests only if needed for compile/behavior lock
- Out of scope:
  - Lifecycle policy changes
  - UMA resolver orchestration behavior changes (`UMATreasurySuccessResolver`)

## Verification plan

- `pnpm -s verify:required`
- completion workflow passes:
  - simplify
  - test-coverage-audit
  - task-finish-review
- rerun `pnpm -s verify:required` after audit pass

## Outcome

- Consolidated treasury-side UMA helper behavior into `src/goals/library/TreasurySuccessAssertions.sol`:
  - pending assertion state + guards,
  - strict truth checks for resolver-driven `resolveSuccess`,
  - fail-closed post-deadline pending assertion resolution checks (+ reason enum).
- Removed redundant helper libraries:
  - deleted `src/goals/library/UMASuccessAssertions.sol`,
  - deleted `src/goals/library/TreasuryUmaAssertionResolution.sol`.
- Updated goal treasury integration + tests:
  - `src/goals/GoalTreasury.sol` now uses `TreasurySuccessAssertions.State` and `FailClosedReason`,
  - `test/goals/GoalTreasury.t.sol` now references `TreasurySuccessAssertions.FailClosedReason`.
- Completion workflow executed:
  - simplify pass: consolidated matcher/tail checks in `TreasurySuccessAssertions`,
  - test-coverage audit: validated budget fail-closed branch coverage,
  - task-finish-review rerun after follow-up fix: no actionable findings.
- Verification evidence:
  - multiple green `pnpm -s verify:required` runs during this task,
  - final post-audit pass green (receipt `20260226T060039Z-pid46374-24087`),
  - focused treasury suites green (`BudgetTreasuryTest` and `GoalTreasuryTest`).

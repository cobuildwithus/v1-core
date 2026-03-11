# Remove Budget Oracle Type Surface

Status: completed
Created: 2026-02-27
Updated: 2026-02-27

## Goal

- Remove vestigial `oracleType`/`maxOracleType` from Budget TCR listing/deployment surfaces.
- Keep behavior aligned with current runtime semantics (UMA assertion metadata hashes + liveness/bond bounds only).

## Scope

- In scope:
  - `src/tcr/interfaces/IBudgetTCR.sol`
  - `src/tcr/library/BudgetTCRValidationLib.sol`
  - `src/tcr/BudgetTCR.sol`
  - Factory/request plumbing that still forwards `maxOracleType`
  - Affected tests under `test/BudgetTCR*.t.sol` and `test/goals/GoalFactory.t.sol`
  - Product/reference docs that currently claim a required oracle type
- Out of scope:
  - Any change under `lib/**`
  - Changes to assertion policy hash/spec hash enforcement

## Success criteria

- `oracleType` is no longer part of budget listing structs, validation bounds, constructor checks, or deployment wiring.
- Validator still enforces non-zero UMA policy/spec hashes and configured liveness/bond values.
- Tests compile and pass with updated interfaces.
- Required Solidity gate passes (`pnpm -s verify:required`).
- Completion workflow passes run (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Notes

- Hard cutover is acceptable under current repo policy (no live deployments as of 2026-02-20).
- Keep worktree-safe behavior: do not revert unrelated dirty changes.

## Verification

- Completion workflow passes run:
  - simplify: completed (behavior-preserving cleanup in validator library/test harness)
  - test-coverage-audit: completed (added GoalFactory oracle-bond forwarding assertion)
  - task-finish-review: completed (no findings in scope)
- Required gate:
  - `pnpm -s verify:required` (failed due unrelated in-flight compile breakage outside this task scope)
    - observed blockers during run window:
      - `src/tcr/BudgetTCR.sol`: stale `PreparationResult.stakeVault` reference during concurrent stack refactors
      - `src/tcr/ERC20VotesArbitrator.sol`: missing newly introduced interface initializers under concurrent arbitrator refactor

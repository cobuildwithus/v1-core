# 2026-02-27 activation-cutoff-fundraising-only-scoring

Status: completed
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Stop budget reward-point accrual once a budget has activated (min threshold met), while preserving funding-deadline cutoff as fallback when activation never occurs.

## Scope

- In scope:
  - `src/interfaces/IBudgetTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/goals/BudgetStakeLedger.sol`
  - Directly affected tests under `test/goals/**`
  - Docs describing reward cutoff behavior (`ARCHITECTURE.md`, `agent-docs/**`)
- Out of scope:
  - `lib/**`
  - Changing reward payout shape (still pro-rata by points)
  - Adding backward-compatibility shims

## Constraints

- Keep permissionless `sync()` activation model (no keeper requirement hardening in this change).
- Activation timestamp is set when treasury transitions `Funding -> Active`.
- Points cutoff remains exogenous and objective from treasury state surfaces.

## Design

1. Add `activatedAt` to `IBudgetTreasury` and treasury lifecycle status.
2. Persist `activatedAt` exactly once in `_activateAndSync()`.
3. Extend ledger budget info to cache activation cutoff metadata at registration.
4. Clamp user/budget/finalization scoring cutoff by `activatedAt` when set:
   - `min(goalSuccessOrNow, removedAt, fundingDeadline, activatedAtIfPresent)`.
5. Preserve deadline fallback behavior for budgets that never activate.
6. Update tests/docs to encode activation-first cutoff semantics.

## Verification Plan

- Required gate: `pnpm -s verify:required` (Solidity touched).
- Completion workflow passes after implementation:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

## Risks

1. Activation timestamp depends on `sync()` call timing, not instantaneous threshold crossing.
   - Accepted tradeoff for this change; document explicitly.
2. Test mock surfaces missing new activation field/method may fail compilation.
   - Update mocks in touched test files only.

## Progress log

- 2026-02-27: Added `activatedAt` to `IBudgetTreasury`, wired lifecycle status exposure, and persisted activation timestamp on `Funding -> Active` transition in `BudgetTreasury`.
- 2026-02-27: Updated `BudgetStakeLedger` cutoff clamping to include `activatedAt` and switched activation-lock removal derivation to `activatedAt != 0`.
- 2026-02-27: Added/updated high-impact tests for activation cutoff semantics and activation-lock behavior, including coverage for missing `activatedAt` interface surface during budget registration.
- 2026-02-27: Updated architecture/spec/reference docs to reflect activation-first cutoff and clarified that `activatedAt` is sync-time/keeper-timing dependent.
- 2026-02-27: Ran required completion workflow passes (`simplify`, `test-coverage-audit`, `task-finish-review`).
- 2026-02-27: Verification passed: `pnpm -s verify:required`.

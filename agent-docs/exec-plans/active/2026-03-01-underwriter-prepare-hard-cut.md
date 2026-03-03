# Underwriter Withdrawal Prepare Hard-Cut

Status: in_progress
Created: 2026-03-01
Updated: 2026-03-01

## Goal

Hard-cut from global budget-resolution withdrawal gating to per-underwriter settlement gating that forces caller-specific slash settlement before stake withdrawal.

## Scope

- In scope:
  - `StakeVault` withdrawal-path cutover to caller-prepared gating.
  - Add batched caller prep entrypoint with cursor state.
  - Add append-only budget enumeration on `BudgetStakeLedger` for historical budget traversal.
  - Interface and test updates needed for compile and behavior coverage.
- Out of scope:
  - Backward-compatibility shims.
  - Changes to `GoalTreasury` lifecycle state progression semantics.

## Constraints

- Preserve existing slash router and escrow idempotence semantics.
- Keep per-user preparation bounded (`maxBudgets`) to avoid unbounded loops.
- Do not touch `lib/**`.
- Run required Solidity verification gate (`pnpm -s verify:required`) before handoff.
- Run completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Acceptance Criteria

- `withdrawGoal/withdrawCobuild` no longer depend on global `allTrackedBudgetsResolved()`.
- Underwriter must complete caller-specific preparation after `goalResolved` to withdraw.
- Preparation iterates an append-only budget list (includes removed budgets).
- For failed/post-activation-expired budgets, preparation must execute `slash(caller)` (or fail/lock if not executable yet).
- Unrelated unresolved budgets no longer globally block all users by default.
- Existing regression proving slash-escape remains valid before fix is complemented by passing tests for new prepare gate.

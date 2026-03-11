# Fail-Closed Factory And Premium Receipt Reads

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Harden two approved paths so trusted deployment probing fails fast and premium receipt accounting fails closed instead of silently downgrading or drifting.

## Scope

- `src/tcr/BudgetTCRFactory.sol`
- `src/goals/PremiumEscrow.sol`
- Focused regressions in TCR/factory and premium-escrow test suites
- Durable docs covering the new fail-fast / fail-closed semantics

## Out Of Scope

- Treasury flow-rate sync fallback behavior changes
- PremiumEscrow manager-reward receipt behavior beyond the goal-flow receipt paths approved for this task
- Broader submission-deposit strategy interface refactors

## Design Constraints

- Keep trusted deployment paths fail-fast on required capability/interface mismatch.
- Preserve the intentional meaning of a clean `supportsEscrowBonding() == false` response.
- Treat goal-flow receipt baseline/checkpoint reads as accounting-critical and fail closed on read failure.
- Keep slash-weight math unchanged; this task should not alter `creditDrawn` distribution rules other than preventing stale receipts from being mis-accounted.

## Planned Work

1. Split `BudgetTCRFactory` deposit-strategy capability probing into explicit `supported=false` vs probe failure, with a specific deployment revert on probe failure.
2. Remove `PremiumEscrow` zero-baseline and silent checkpoint-return fallbacks for goal-flow receipt reads; replace them with explicit custom errors.
3. Add regression tests for factory probe failure and premium receipt baseline/checkpoint read failure paths.
4. Update architecture/spec docs to describe the trusted deployment and accounting fail-closed behavior.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Outcome

- Targeted fail-closed fallout tests now pass for the factory, premium escrow, shared goal-flow harnesses, and dependent deployment/wiring suites.
- Final repo-wide verification passed after shared-worktree cleanup via `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

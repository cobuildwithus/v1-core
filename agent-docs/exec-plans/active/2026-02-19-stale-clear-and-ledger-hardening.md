# Stale Clear and Ledger Hardening

Status: in_progress
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Implement agreed protocol hardening fixes while deferring the goal-success grace/cutoff policy decision.

## Scope

- In scope:
  - Permissionless stale allocation clear path when current strategy weight is zero.
  - Budget stake ledger tracked-budget hard cap to bound historical-growth loops.
  - Fail-closed budget resolution detection for undeployed budget treasuries.
  - Earlier allocation-ledger configuration enforcement (single strategy + deployed treasury wiring).
  - Regression/behavior tests for each change.
- Out of scope:
  - Goal success grace-period/cutoff policy changes.
  - Reward dust sweep policy changes.

## Constraints

- No changes under `lib/**`.
- Preserve existing storage layout and external behavior except where explicitly hardened.
- Run mandatory verification: `forge build -q`, `pnpm -s test:lite`.

## Tasks

1. Add permissionless stale clear entrypoint to `CustomFlow`.
2. Add tracked-budget cap enforcement in `BudgetStakeLedger`.
3. Switch `BudgetStakeStrategy` undeployed treasury handling to fail-closed.
4. Tighten `Flow.setAllocationLedger` upfront validation gates.
5. Update and add tests to prove hardened behavior.
6. Run required verification commands.

## Verification

- Pending

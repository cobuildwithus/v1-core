# Fixed Tau Hard Cutover

Status: active
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Hard-cut over budget warmup from per-budget window-derived maturation to a fixed global maturation period (`tau = 6 hours`) to remove deadline/window gaming and activation-vs-deadline miscalibration.

## Acceptance criteria

- `BudgetStakeLedger` uses a fixed global maturation period (`6 hours`) for all accrual/preview/finalization paths.
- Per-budget maturation metadata is removed from storage and `IBudgetStakeLedger.BudgetInfoView`.
- Window-derived maturation constants/helpers are removed.
- Ledger/reward tests compile and pass with fixed-tau semantics.
- Canonical docs describe fixed maturation semantics.
- Required verification for Solidity edits passes: `pnpm -s verify:required`.

## Scope

- In scope:
  - `src/goals/BudgetStakeLedger.sol`
  - `src/interfaces/IBudgetStakeLedger.sol`
  - affected goal/reward tests
  - architecture/spec/reference docs that define maturation semantics
- Out of scope:
  - `lib/**`
  - payout formula shape (`pro-rata by normalized points` remains unchanged)
  - treasury activation/deadline cutoff logic

## Decisions

- Use fixed global `tau = 6 hours`.
- Remove `maturationPeriodSeconds` from `BudgetInfo` and `BudgetInfoView`.
- Keep scoring-window normalization and exogenous cutoff behavior unchanged.

## Progress log

- 2026-02-27: Claimed scope in `COORDINATION_LEDGER` and reviewed required architecture/spec/security/runtime docs.
- 2026-02-27: Implemented fixed-tau cutover in `BudgetStakeLedger` and removed interface/storage maturation metadata.
- 2026-02-27: Updated affected tests and canonical docs for fixed `tau = 6 hours`.
- 2026-02-27: Targeted tests passed (`BudgetStakeLedgerEconomics`, `BudgetStakeLedgerBranchCoverage`, `RewardEscrow`).

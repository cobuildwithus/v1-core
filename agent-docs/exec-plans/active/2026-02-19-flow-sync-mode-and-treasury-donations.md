# Exec Plan: Flow Sync Mode and Treasury Donations

Date: 2026-02-19
Owner: Codex
Status: Completed

## Goal
- Preserve nested-flow topology while isolating budget-child flow-rate control to treasury managers.
- Remove/restrict permissionless flow-rate mutation surfaces.
- Add direct donation entrypoints on treasuries (SuperToken + underlying auto-upgrade).

## Scope
- `src/Flow.sol`
- `src/storage/FlowStorage.sol`
- `src/interfaces/IFlow.sol`
- `src/interfaces/IManagedFlow.sol`
- `src/library/FlowRates.sol`
- `src/tcr/BudgetTCR.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/interfaces/IGoalTreasury.sol`
- `src/interfaces/IBudgetTreasury.sol`
- flow/goal/budget/tcr-related tests and mocks
- architecture/reference docs

## Decisions
- Add per-child sync mode to flow recipients:
  - Parent-synced (default)
  - Manager-synced (used for budget children)
- Parent child-sync queue skips manager-synced children.
- BudgetTCR marks newly deployed budget children as manager-synced.
- Remove/reset permissionless rate surfaces where feasible; role-gate remaining entrypoints required for parent-managed child internals.
- Donations move to treasury entrypoints; goal donations update `totalRaised`, budget donations remain balance-only.

## Risks
- Child-sync mode wiring regressions across allocation and recipient lifecycle.
- Budget stack runtime assumptions around goal-flow manager authority.
- Treasury donation token-conversion edge cases.

## Verification
- `forge build -q`
- `pnpm -s test:lite`
- Result: pass (`626` tests, `0` failed on 2026-02-19).

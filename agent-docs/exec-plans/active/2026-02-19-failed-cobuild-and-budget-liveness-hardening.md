# 2026-02-19 failed-cobuild-and-budget-liveness-hardening

## Goal
Harden terminal-state behavior by:
- ensuring failed escrow cobuild sweeps do not strand in goal treasury,
- adding permissionless retry for removed-but-unresolved budget stacks,
- adding permissionless late residual settlement for finalized budget treasuries,
- adding sorted/unique defense-in-depth checks in budget stake ledger checkpointing.

## Scope
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/tcr/BudgetTCR.sol`
- `src/interfaces/{IGoalTreasury,IBudgetTreasury,IBudgetTCR}.sol`
- related tests and docs

## Verification
- `forge build -q`
- targeted forge tests for touched modules
- `pnpm -s test:lite`

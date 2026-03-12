# 2026-03-12 Open Prune And Managed Gate Cleanups

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Close the remaining narrow follow-up gaps from the archive review without widening the shared deployment architecture in this pass.

## Scope

- In scope:
  - `src/tcr/BudgetTCR.sol`
  - `src/goals/GoalFactory.sol`
  - `src/goals/library/GoalFactoryManagedPresetDeploy.sol`
  - `src/allocation-strategies/BudgetSingleAllocatorStrategy.sol`
  - targeted tests covering open-lane batch sync, managed preset goal-factory wiring, and budget single-allocator validation
  - touched preset/runtime docs that describe managed gate-policy wiring or batch-sync prune semantics
- Out of scope:
  - deleting or redesigning `NullPremiumEscrow`
  - changing shared `IPremiumEscrow` or `BudgetTCRStackDeploymentLib` seams
  - converging deployers or retopologizing managed/open controller composition
  - broad dead-code deletion beyond wiring/test fallout needed for this pass

## Constraints

- Preserve existing open-lane activation/removal semantics; the new local prune path is only a fallback after a successful treasury sync leaves the budget terminal.
- Managed preset should represent “no gate policy” directly with `address(0)` and should not depend on a deployed no-op gate module.
- Do not disturb unrelated in-flight managed-controller trimming or other dirty worktree changes.

## Intended change

1. Add a local open-lane terminal-prune helper in `BudgetTCR` and reuse it from both `pruneTerminalBudget(...)` and `syncBudgetTreasuries(...)` after a successful terminalizing `treasury.sync()`.
2. Stop wiring `NoopBudgetGatePolicy` into the managed preset path in `GoalFactory`; initialize managed controllers with a zero gate-policy address instead.
3. Align `BudgetSingleAllocatorStrategy` constructor validation with `SingleAllocatorStrategy` by requiring the allocator to be a contract.
4. Update the focused tests/docs that assert the old managed no-op gate wiring or lack the new open-lane prune fallback behavior.

## Verification

- targeted forge tests for touched paths
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s build:sizes`
- completion workflow: `simplify` -> `test-coverage-audit` -> `task-finish-review`

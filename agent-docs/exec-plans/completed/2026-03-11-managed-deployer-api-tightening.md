# 2026-03-11 Managed Deployer API Tightening

Status: completed
Created: 2026-03-11
Updated: 2026-03-12

## Goal

- Remove unused managed-stack preparation inputs from `ManagedBudgetControllerStackDeployer.prepareBudgetStack(...)`.
- Replace the local `BudgetTreasury` prune shim with the canonical controller interface.

## Scope

- In scope:
  - `src/interfaces/IBudgetController.sol`
  - `src/interfaces/IManagedBudgetControllerStackDeployer.sol`
  - `src/goals/ManagedBudgetControllerStackDeployer.sol`
  - `src/goals/ManagedBudgetController.sol`
  - `src/goals/BudgetTreasury.sol`
  - focused managed/controller regression tests
- Out of scope:
  - open-preset deployer APIs
  - budget treasury lifecycle changes beyond interface typing
  - managed allocator/runtime behavior changes

## Constraints

- Preserve current managed runtime behavior; only remove unused prep-time baggage.
- Use the canonical controller seam from `src/interfaces/**` instead of a local one-off shim.
- Do not disturb the in-flight `BudgetTreasury` removal cleanup already present in the worktree.

## Intended change

1. Shrink the managed `prepareBudgetStack(...)` interface and implementation to the controller input actually required.
2. Update `ManagedBudgetController` and test mocks/call sites to match the smaller signature.
3. Swap `BudgetTreasury` terminal prune typing from the local shim to `IBudgetController`.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- completion workflow passes if required by repo policy

## Outcome

- Managed stack preparation now takes only `controller`.
- `BudgetTreasury` now calls `pruneTerminalBudget(...)` through the canonical `IBudgetController` seam.
- Focused managed deployer and managed controller prune regressions passed.
- `pnpm -s lint:solidity:warnings` passed.
- `pnpm -s verify:required` failed twice on the same unrelated pre-existing fuzz failure in `test/flows/FlowLedgerChildSyncProperties.t.sol`.

# 2026-03-12 Budget Stack Architecture Cleanup

Status: completed
Created: 2026-03-12
Completed: 2026-03-12

## Goal

- Finish the remaining budget-stack cleanup around:
  - open-lane terminal prune fallback parity,
  - neutral shared budget deployment config,
  - managed preset convergence onto the generic stack deployer,
  - shared stateless managed null-escrow wiring.

## Shipped

- `BudgetTCR.syncBudgetTreasuries(...)` now runs an idempotent local terminal-prune fallback after successful terminalizing treasury syncs.
- Shared budget deployment now uses neutral `IBudgetTreasury.BudgetConfig` plus `IBudgetStackDeployer.RiskModuleInitConfig` instead of routing everything through `IBudgetTCR.BudgetListing`.
- Managed preset deployment now clones/configures `BudgetTCRDeployer` through `IBudgetStackDeployer` instead of using `ManagedBudgetControllerStackDeployer`.
- `NullPremiumEscrow` is now a shared stateless shim.
- Managed preset uses `budgetGatePolicy = address(0)` and a child-strategy factory backed by cloneable `BudgetSingleAllocatorStrategy`.
- Spend-policy validation was centralized in `SpendPolicyValidationLib` and hardened against invalid and malformed `syncMode()` ABI responses.
- Live architecture docs were updated to describe the shared stack-deployer boundary.

## Follow-Up Fixes During Review

- Fail-closed `ManagedBudgetController` so managed stacks must still use the controller itself as child-flow `recipientAdmin`.
- Restored clone-only deployment semantics for managed budget child strategies by making `BudgetSingleAllocatorStrategy` cloneable/initializable and updating its factory to use `Clones.clone(...)`.
- Added regression coverage for malformed `syncMode()` ABI responses.

## Verification

- `forge build`
- Focused forge suites covering `BudgetTCR`, deployer/config seams, managed controller wiring, `GoalFactory`, and `BudgetSingleAllocatorStrategy`
- `pnpm -s verify:required`
  - passed before final follow-up fix
  - final rerun was blocked by an unrelated syntax error in `test/mocks/FakeUMATreasurySuccessResolver.t.sol`
- `pnpm -s build:sizes`

## Notes

- Completion workflow passes run for this task: `simplify`, `test-coverage-audit`, `task-finish-review`.
- A coverage subagent created an intermediate local commit despite instructions not to commit; parent integration continued from the resulting tree and finished review/fixes in the main lane.

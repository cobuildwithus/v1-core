# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-budget-stack-prepare-simplification | Remove dead prepare-budget-stack interface plumbing | `src/tcr/interfaces/IBudgetTCRStackDeployer.sol`, `src/tcr/library/BudgetTCRStackActions.sol`, `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/library/BudgetTCRStackDeploymentLib.sol`, `test/BudgetTCRDeployments.t.sol`, `test/BudgetTCRBudgetTreasuryInvariant.t.sol`, `agent-docs/exec-plans/active/2026-03-10-budget-stack-prepare-simplification.md` | delete unused `prepareBudgetStack` parameters `goalToken`, `cobuildToken`, `goalRulesets`, `goalRevnetId`, `paymentTokenDecimals`, `budgetSlashPpm`; delete `BudgetTCRStackDeploymentLib.prepareBudgetStack` and its `PreparationResult`; preserve deployer/interface `PreparationResult` shape | No active ledger overlap on these files; keep stack preparation behavior unchanged except for removing dead argument threading and inlining equivalent validation in the deployer | 2026-03-10 |
| codex-explicit-flow-allocation-apis | Make allocation runtime context explicit and move canonical external reads onto `CustomFlow` | `src/interfaces/IAllocationStrategy.sol`, `src/interfaces/IAllocationPipeline.sol`, `src/interfaces/IBudgetFlowRouterStrategy.sol`, `src/interfaces/IFlow.sol`, `src/interfaces/IStakeVault.sol`, `src/interfaces/IGoalLedgerStrategy.sol`, `src/flows/CustomFlow.sol`, `src/library/CustomFlowAllocationEngine.sol`, `src/library/CustomFlowPreview.sol`, `src/allocation-strategies/BudgetFlowRouterStrategy.sol`, `src/hooks/GoalFlowAllocationLedgerPipeline.sol`, `src/goals/StakeVault.sol`, `src/teamflow/TeamFlow.sol`, targeted `test/**`, `agent-docs/references/flow-allocation-and-child-sync-map.md`, `agent-docs/references/module-boundary-map.md`, `agent-docs/exec-plans/active/2026-03-10-explicit-flow-allocation-apis.md` | change `IAllocationStrategy.currentWeight/canAllocate` signatures to include `flow`; delete base `canAccountAllocate` and `accountAllocationWeight`; add `CustomFlow` allocation read helpers; rename budget-router `closed` plumbing; change pipeline preview to accept explicit `flow` | Preserve unrelated in-flight edits already present in `GoalFlowAllocationLedgerPipeline`; breaking ABI change is intentional and all call sites/tests in scope must be updated together | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

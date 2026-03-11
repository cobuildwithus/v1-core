# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-budget-stack-prepare-simplification | Remove dead prepare-budget-stack interface plumbing | `src/tcr/interfaces/IBudgetTCRStackDeployer.sol`, `src/tcr/library/BudgetTCRStackActions.sol`, `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/library/BudgetTCRStackDeploymentLib.sol`, `test/BudgetTCRDeployments.t.sol`, `test/BudgetTCRBudgetTreasuryInvariant.t.sol`, `agent-docs/exec-plans/active/2026-03-10-budget-stack-prepare-simplification.md` | delete unused `prepareBudgetStack` parameters `goalToken`, `cobuildToken`, `goalRulesets`, `goalRevnetId`, `paymentTokenDecimals`, `budgetSlashPpm`; delete `BudgetTCRStackDeploymentLib.prepareBudgetStack` and its `PreparationResult`; preserve deployer/interface `PreparationResult` shape | No active ledger overlap on these files; keep stack preparation behavior unchanged except for removing dead argument threading and inlining equivalent validation in the deployer | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

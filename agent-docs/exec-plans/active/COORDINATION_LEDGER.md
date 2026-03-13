# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.
Rows are active-work notices by default, not hard file locks.
Use dependency notes to mark a lane as exclusive when overlap is unsafe, such as a large refactor or delicate cross-cutting rewrite.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-budget-stack-validation | Managed/open stack validation cleanup | `src/goals/ManagedBudgetController.sol`, `src/interfaces/IManagedBudgetController.sol`, `src/goals/GoalFactory.sol`, `src/tcr/library/BudgetTCRStackActions.sol`, `src/tcr/library/BudgetTCRInitValidation.sol`, `src/tcr/interfaces/IBudgetTCR.sol`, `src/goals/library/BudgetStackInstantiationLib.sol`, targeted `test/**`, touched `agent-docs/**`, `ARCHITECTURE.md` | delete `budgetChildStrategyFactory` init arg; add managed/open prepared-stack validation errors/checks; split no-risk instantiation helper path; adjust zero-bond validation/tests/docs | Must preserve shared stack deployer semantics and avoid touching unrelated dirty deploy artifacts; audit subagents must not edit owned files without re-reading this ledger | 2026-03-13 |
| codex-deploy-goal-script-cleanup | One-shot deploy-goal smoke script defaults | `script/DeployGoalFromFactory.s.sol`, targeted `test/mocks/FakeUMATreasurySuccessResolver.t.sol` | add artifact-backed fake resolver lookup helpers/errors; no production contract symbol renames | Avoid touching active managed budget stack files; keep change scoped to deploy-script/test wiring only | 2026-03-13 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

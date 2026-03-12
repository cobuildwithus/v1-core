# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-test-coverage-audit-dup-cleanup | Coverage audit for managed controller deploy-path regressions in duplication cleanup batch | `test/goals/ManagedBudgetController.t.sol` | add test-only deploy-path/risk-init capture on `ManagedBudgetControllerMockStackDeployer`; add focused assertions for no-premium vs premium treasury deployment branch selection | Audit pass only; do not touch parent-owned production files or other active lane files | 2026-03-12 |
| codex-main-budget-no-premium-surface | Remove dead budget deployer args, make risk wiring mode-aware, canonicalize zero-rate premium absence, and collapse the legacy open initializer | `agent-docs/exec-plans/active/2026-03-12-budget-no-premium-surface-cleanup.md`, `src/interfaces/IBudgetStackDeployer.sol`, `src/tcr/interfaces/IBudgetTCRDeployer.sol`, `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/BudgetTCRFactory.sol`, `src/tcr/library/BudgetTCRInitValidation.sol`, `src/tcr/library/BudgetTCRStackDeploymentLib.sol`, `src/tcr/library/BudgetTCRStackActions.sol`, `src/goals/ManagedBudgetController.sol`, targeted tests | delete `prepareBudgetStack(... underwriterSlasherRouter)` arg and legacy `initialize(...)`; add mode-aware budget treasury deploy entrypoints and zero-rate premium canonicalization helpers | This lane owns end-to-end integration, verification, and commit flow for the explicit no-premium deployer surface; avoid unrelated files and do not revert concurrent worktree edits | 2026-03-12 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

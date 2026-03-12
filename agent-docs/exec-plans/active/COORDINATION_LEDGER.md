# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-no-premium-gate-validation | Make no-premium and zero-slash premium-module validation consistent across deployer and init boundaries | `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/library/BudgetTCRInitValidation.sol`, `src/tcr/BudgetTCR.sol`, `src/tcr/interfaces/IBudgetTCR.sol`, `test/BudgetTCR.t.sol`, `test/BudgetTCRDeployments.t.sol` | Add premium-module config mismatch validation and regressions; no symbol deletions planned | Keep scope off the managed-terminal-rollover lane; avoid unrelated doc or GoalTreasury churn while tightening the premium presence invariant | 2026-03-12 |
| codex-no-premium-simplify-pass | Simplify pass for no-premium invariant cutover in owned BudgetTCR files | `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/library/BudgetTCRInitValidation.sol`, `src/tcr/BudgetTCR.sol`, `src/tcr/interfaces/IBudgetTCR.sol`, `test/BudgetTCR.t.sol` | No symbol changes planned; behavior-preserving cleanup only | Respect existing no-premium validation ownership; do not touch `test/BudgetTCRDeployments.t.sol` or unrelated active rows | 2026-03-12 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

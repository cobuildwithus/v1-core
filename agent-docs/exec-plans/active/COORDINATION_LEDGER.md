# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| Codex-main | Standardize shared repo-tools/review-gpt integration and dependency bumps | `scripts/repo-tools.config.sh`, `package.json`, `pnpm-lock.yaml` | No Solidity/runtime symbol changes expected | Tooling-only rollout; avoid active protocol implementation files owned by Codex-main-4 | 2026-03-07 |
| Codex-main-budget-spend-cutover | Hard-cut budget spend policies to explicit linear policy defaults; remove units-cap policy | `src/interfaces/ISpendPolicy.sol`, `src/goals/policies/LinearSpendPolicy.sol`, `src/goals/policies/UnitsCapSpendPolicy.sol`, `src/goals/GoalTreasury.sol`, `src/goals/BudgetTreasury.sol`, `src/tcr/library/BudgetTCRStackDeploymentLib.sol`, targeted `test/goals/**`, `test/invariant/**`, matching `agent-docs/**`, `ARCHITECTURE.md` | Delete `UnitsCapSpendPolicy`; remove `SpendContext.totalRecipientUnits`; add `LinearSpendPolicy.maxTargetFlowRate`; delete zero-policy budget branch; thread BudgetTCR-wide default budget spend policy through stack deploy | Preserve current budget runtime semantics via explicit linear policy config; avoid unrelated active TCR event files owned by `Codex-main-tcr-events` | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| Codex-main-2 | Make StakeVault treasury metadata fallback fail closed | `src/interfaces/IStakeVault.sol`, `src/goals/StakeVault.sol`, `test/goals/StakeVault.t.sol` | Add fail-closed weight metadata read error; remove optimistic boosted fallback behavior/tests | Keep goal stake weight accounting conservative when required treasury metadata reads fail; avoid touching active flow allocation work | 2026-03-07 |
| Codex-main-3 | Share treasury success-assertion post-deadline lifecycle helper without coupling full lifecycle policy | `src/goals/library/TreasurySuccessAssertionLifecycle.sol`, `src/goals/GoalTreasury.sol`, `src/goals/BudgetTreasury.sol`, treasury tests/docs as needed | Add shared lifecycle helper for duplicated assertion clear/finalize wrapper logic; delete local duplicate helpers only if behavior stays identical | Shared hot spots with active treasury telemetry work; keep event surface and treasury-specific reassert/finalize policy stable | 2026-03-07 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

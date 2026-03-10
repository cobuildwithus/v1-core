# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-low-impact-cleanups | Validate and apply low-impact protocol simplifications | `src/goals/GoalTreasury.sol`, `src/library/FlowPools.sol`, `src/Flow.sol`, `src/teamflow/TeamFlow.sol`, `agent-docs/exec-plans/active/2026-03-10-low-impact-protocol-cleanups.md` | delete `_raisedForLifecycle`; delete `removeFromPools`; preserve `recordHookFunding` unless safe removal becomes proven | Avoid interface changes unless usage analysis proves they are safe; no behavior change intended for goal min-raise or recipient removal paths | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| managed-preset-coordination | Freeze managed-goal preset names, boundaries, and stream ownership | `agent-docs/exec-plans/active/2026-03-11-managed-goal-preset-master-plan.md`; `agent-docs/references/module-boundary-map.md`; `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | add `2026-03-11-managed-goal-preset-master-plan.md`; freeze names `IBudgetController`, `IBudgetGatePolicy`, `ManagedBudgetController`, `NullPremiumEscrow`, `IGoalScopedAllocationStrategy`, `SingleAllocatorStrategy`; no Solidity edits | Coordination-only stream; future implementation agents must add separate rows before touching code and must follow the frozen boundaries in the master plan | 2026-03-11 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

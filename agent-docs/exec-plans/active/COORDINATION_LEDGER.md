# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.
Rows are active-work notices by default, not hard file locks.
Use dependency notes to mark a lane as exclusive when overlap is unsafe, such as a large refactor or delicate cross-cutting rewrite.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-goalfactory-typed-deploy | Split GoalFactory internal deploy union into typed open/managed paths | `src/goals/GoalFactory.sol`, `test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol`, task plan doc | delete `InternalDeployParams`, delete `_deployGoal`, delete `_openDeployParams`, delete `_managedDeployParams`; add `_deployOpenGoal`, `_deployManagedGoal`, typed shared validation/finalization helpers; add managed-community wrapper guard regression | Active refactor lane in `GoalFactory.sol` and focused GoalFactory guard tests; preserve adjacent edits and avoid touching unrelated dirty files. | 2026-03-13 |
| codex-treasury-sync-base | Unify treasury success-assertion accessor/event plumbing and the shared flow-rate sync shell | `src/goals/BudgetTreasury.sol`, `src/goals/GoalTreasury.sol`, `src/goals/TreasurySuccessAssertionMixin.sol`, `src/interfaces/IBudgetTreasury.sol`, `src/interfaces/IGoalTreasury.sol`, `src/interfaces/ITreasuryFlowRateSyncEvents.sol`, possible small shared treasury interface file(s), `agent-docs/exec-plans/active/2026-03-13-treasury-sync-success-assertion-base.md` | add shared treasury runtime/accessor interface/base hooks; move shared `_syncFlowRate` skeleton and success-assertion emitter helpers into the shared base; delete duplicated public accessor wrappers, duplicated emitter overrides, and duplicated `_syncFlowRate` shells in goal/budget treasuries | Inheritance-shape refactor limited to treasury modules/interfaces; preserve goal/budget lifecycle semantics, event signatures, and target-rate calculation differences. | 2026-03-13 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

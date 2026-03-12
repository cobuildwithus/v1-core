# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-main | Implement budget-stack architecture cleanup and verification | `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`, `agent-docs/exec-plans/active/2026-03-12-budget-stack-architecture-workers.md`, `src/interfaces/IBudgetStackDeployer.sol`, `src/interfaces/IBudgetStackChildFlowStrategyFactory.sol`, `src/library/SpendPolicyValidationLib.sol`, `src/tcr/BudgetTCR.sol`, `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/interfaces/IBudgetTCRChildFlowStrategyFactory.sol`, `src/tcr/interfaces/IBudgetTCRDeployer.sol`, `src/tcr/interfaces/IBudgetTCRStackDeployer.sol`, `src/tcr/library/BudgetTCRStackDeploymentLib.sol`, `src/tcr/library/BudgetTCRStackActions.sol`, `src/goals/GoalFactory.sol`, `src/goals/ManagedBudgetController.sol`, `src/goals/NullPremiumEscrow.sol`, `src/goals/library/GoalFactoryManagedPresetDeploy.sol`, `src/allocation-strategies/BudgetSingleAllocatorStrategyFactory.sol`, affected tests, and matching live architecture docs | Add generic stack-deployer interfaces/factory; delete managed-only deployer path; make `NullPremiumEscrow` stateless/shared; harden spend-policy validation probe; keep open-lane local prune fallback idempotent; update tests/docs to match new managed/open deployment seams | Parent owns final integration, verification, completion passes, and commit; do not overwrite unrelated dirty paths | 2026-03-12 |
| codex-main | Orchestrate codex-4 simplification batch for targets 1 and 4 | `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`, `agent-docs/exec-plans/active/2026-03-12-simplification-worker-batch-14.md` | Add batch-14 plan doc; reserve active worker ownership rows for spend-policy helper and managed active-state derivation; no production-symbol changes in parent lane | Parent-managed orchestration only; child workers must not edit ledger unless scope must change and should otherwise report blockers | 2026-03-12 |
| codex-worker-t1-spend-policy | Unify duplicated spend-policy validation probe behind one shared helper | `src/goals/TreasuryBase.sol`, `src/goals/GoalFactory.sol`, `src/tcr/library/BudgetTCRInitValidation.sol`, optional shared helper library, related tests | Add shared spend-policy validation helper; replace duplicated probe logic at three call sites; preserve caller-specific custom errors | Safe to run now that the old GoalFactory/BudgetTCR wiring lanes are clean; keep scope off unrelated deploy/controller refactors | 2026-03-12 |
| codex-worker-t4-managed-active-derived | Derive managed budget active state from index mapping instead of storing duplicate bool | `src/goals/ManagedBudgetController.sol`, `src/interfaces/IManagedBudgetController.sol`, related managed-controller tests | Delete stored `BudgetDeployment.active` field if safe; derive `active` from `_activeBudgetIndexPlusOne`; update views/tests consistently | Keep this lane narrowly on derived state; do not fold in topology helper dedupe or controller-runtime extraction | 2026-03-12 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

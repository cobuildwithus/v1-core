# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-main | Inject shared open budget gate policy from implementation deploy artifacts; remove BudgetTCR self-deploy fallback and externalize open-preset init/gate sync logic | `src/tcr/BudgetTCR.sol`, `src/tcr/library/BudgetTCRInitValidation.sol`, `src/tcr/library/BudgetTCRGateSync.sol`, `src/goals/GoalFactory.sol`, `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`, `script/DeployGoalFactoryImplementations.s.sol`, `script/DeployGoalFactory.s.sol`, related tests | Add `OPEN_BUDGET_GATE_POLICY` immutable + wiring; remove BudgetTCR zero-default self-deploy path; add linked `BudgetTCRInitValidation`; link BudgetTCR gate-sync helper instead of inlining it | Keep managed gate policy wiring unchanged; update constructor/deploy artifact call sites consistently; preserve open-preset validation semantics while shrinking runtime | 2026-03-12 |
| codex-main | Prune dead managed-only `NullPremiumEscrow` storage/getters | `src/goals/NullPremiumEscrow.sol`, `test/BudgetTCRDeployments.t.sol`, `test/BudgetTCRManagedStackDeployments.t.sol`, `test/goals/ManagedBudgetController.t.sol`, `test/goals/ManagedBudgetControllerStackDeployer.t.sol` | Delete `budgetStakeLedger`, `underwriterSlasherRouter`, `budgetSlashPpm` storage/getters from `NullPremiumEscrow`; remove stale test assertions that depend on them; keep `initialize(...)` signature unchanged | No in-repo production callers read those getters; preserve `budgetTreasury`/`goalFlow` seam and shared `IPremiumEscrow` initializer shape | 2026-03-12 |
| codex-main | Trim managed-controller unused config/storage surface | `src/interfaces/IManagedBudgetController.sol`, `src/interfaces/IManagedBudgetControllerStackDeployer.sol`, `src/goals/ManagedBudgetController.sol`, `src/goals/ManagedBudgetControllerStackDeployer.sol`, `src/goals/library/GoalFactoryManagedPresetDeploy.sol`, `src/goals/GoalFactory.sol`, managed-focused tests/docs | Delete managed `budgetAllocationLedger`/`underwriterSlasherRouter`/`budgetPremiumPpm`/`budgetSlashPpm` init+getter surface; remove managed deployer args for ledger/router/slash; add explicit zeroed managed gate/deploy wiring at use sites; simplify post-trim init plumbing only where behavior is unchanged | Must layer cleanly on current `GoalFactory.sol` open-budget-gate diff; do not touch active `NullPremiumEscrow` getter-prune work | 2026-03-12 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

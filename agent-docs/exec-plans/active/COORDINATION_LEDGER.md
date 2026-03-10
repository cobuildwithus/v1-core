# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| Codex-main | Standardize shared repo-tools/review-gpt integration and dependency bumps | `scripts/repo-tools.config.sh`, `package.json`, `pnpm-lock.yaml` | No Solidity/runtime symbol changes expected | Tooling-only rollout; avoid active protocol implementation files owned by Codex-main-4 | 2026-03-07 |
| Codex-main-teamflow | Add TeamFlow mechanism/factory and multi-factory budget mechanism allowlisting | `src/tcr/AllocationMechanismTCR.sol`, `src/tcr/interfaces/IBudgetTCR.sol`, `src/tcr/interfaces/IBudgetTCRStackDeployer.sol`, `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/BudgetTCRFactory.sol`, `src/tcr/library/BudgetTCRStackActions.sol`, `script/DeployGoalFactoryImplementations.s.sol`, new `src/teamflow/**`, targeted `test/rounds/**`, targeted `test/BudgetTCR*.t.sol`, new `test/teamflow/**`, matching `agent-docs/**` | Add `TeamFlow` and `TeamFlowFactory`; widen `AllocationMechanismTCR.initialize` to initial factory arrays; seed initial factory discovery; add TeamFlow seat add/remove/sync symbols and TeamFlow factory budget-context guards | Shared touch points with budget deployer and TCR discovery; preserve active spend-cutover and TCR-event diffs and avoid unrelated GoalFactory/community-registry work | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

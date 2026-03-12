# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-main-uma-zero-em | Remove escalation-manager configurability from v1 UMA success assertions | `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`, `agent-docs/exec-plans/active/2026-03-12-uma-zero-escalation-manager.md`, `src/goals/UMATreasurySuccessResolver.sol`, `src/goals/library/TreasurySuccessAssertions.sol`, `src/interfaces/IUMATreasurySuccessResolverConfig.sol`, `src/mocks/FakeUMATreasurySuccessResolver.sol`, `test/goals/helpers/TreasuryUmaResolverMocks.sol`, `test/goals/UMATreasurySuccessResolver.t.sol`, `test/goals/BudgetTreasury.t.sol`, `test/goals/UnderwritingIntegration.t.sol`, `test/mocks/FakeUMATreasurySuccessResolver.t.sol`, `script/DeployGoalFactoryImplementations.s.sol`, `scripts/solidity-lint-warning-baseline.tsv`, `agent-docs/references/uma-deployment-recommendations.md` | Delete resolver-config `escalationManager()` and `domainId()` getters; hardcode zero escalation manager and zero domain in resolver/fake resolver; reject non-zero EM policy bits in treasury assertion validation; drop fake-resolver EM/domain deployment env handling; refresh shifted warning-baseline location | Overlaps active UMA registry ownership in resolver/tests; keep edits minimal, preserve unrelated changes, and do not touch registry-specific files/docs in that lane | 2026-03-12 |
| codex-worker-premium-core | Blocked on overlapping ownership for core optional-premium mode | `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`, `agent-docs/exec-plans/active/2026-03-12-premium-module-composability-workers.md`, `src/interfaces/IBudgetStackDeployer.sol`, `src/interfaces/IBudgetTreasury.sol`, `src/goals/BudgetTreasury.sol`, `src/tcr/library/BudgetTCRStackDeploymentLib.sol`, `test/goals/BudgetTreasury.t.sol` | Add explicit no-premium mode in shared deployer/treasury seam; allow `premiumEscrow == address(0)` in the owned shared path; skip premium init/close hooks when absent | BLOCKED: `src/interfaces/IBudgetTreasury.sol` and `src/goals/BudgetTreasury.sol` are already owned by `codex-uma-doc-registry`; `test/goals/BudgetTreasury.t.sol` is already owned by both `codex-uma-doc-registry` and `codex-main-uma-zero-em`. Live dirty state is also present in `src/goals/BudgetTreasury.sol` and `test/goals/BudgetTreasury.t.sol`. No Solidity edits made. | 2026-03-12 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

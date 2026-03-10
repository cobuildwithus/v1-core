# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| Codex-main | Standardize shared repo-tools/review-gpt integration and dependency bumps | `scripts/repo-tools.config.sh`, `package.json`, `pnpm-lock.yaml` | No Solidity/runtime symbol changes expected | Tooling-only rollout; avoid active protocol implementation files owned by Codex-main-4 | 2026-03-07 |
| Codex-main-teamflow-runtime | Refactor TeamFlow into a concrete Flow runtime and remove standalone child CustomFlow indirection | `src/teamflow/TeamFlow.sol`, `src/teamflow/TeamFlowFactory.sol`, `test/teamflow/TeamFlowFactory.t.sol`, `ARCHITECTURE.md`, `agent-docs/cobuild-protocol-architecture.md`, `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`, `agent-docs/references/tcr-and-arbitration-map.md` | Add TeamFlow flow initializer/helpers; delete child-flow wiring from factory/tests/docs; update payout recipient semantics to `mechanism == payoutRecipient` | Avoid touching unrelated active routing work; preserve mechanism escrow release flow and AllocationMechanismTCR interface shape | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

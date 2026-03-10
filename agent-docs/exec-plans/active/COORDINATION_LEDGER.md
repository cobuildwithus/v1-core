# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| Codex-main | Standardize shared repo-tools/review-gpt integration and dependency bumps | `scripts/repo-tools.config.sh`, `package.json`, `pnpm-lock.yaml` | No Solidity/runtime symbol changes expected | Tooling-only rollout; avoid active protocol implementation files owned by Codex-main-4 | 2026-03-07 |
| Codex-main-routing-core-integration | Add real-core integration tests showing Cobuild wrapper pending-route assumptions break against async reserved-token distribution | `test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol`, `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | Add new integration test contract/helpers only; no production symbol changes | Keep off active TeamFlow files; do not edit current wrapper/hook production files in this step; use actual `nana-core-v5` controller split distribution semantics rather than same-tx mock consumption | 2026-03-10 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

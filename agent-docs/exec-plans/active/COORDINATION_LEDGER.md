# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-shared-terminal-cutover | Shared goal/community terminal cutover + tests | `src/juicebox/CobuildTerminal.sol`, `src/juicebox/CobuildPaymentTerminal.sol`, `src/juicebox/CobuildPaymentTerminalFactory.sol`, `src/goals/GoalFactory.sol`, `src/tcr/CommunityGoalRegistry.sol`, related deploy scripts/tests including `test/GeneralizedTCRSubmissionDeposits*.t.sol` | Add `CommunityConfig`, `FundingContext`, funding-context validation/helpers, stake-vault-aware test doubles; remove dedicated terminal factory pair assumptions | Must keep goal registry, split-hook, deployment scripts, and generalized-TCR community fixtures aligned on treasury funding context | 2026-03-11 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

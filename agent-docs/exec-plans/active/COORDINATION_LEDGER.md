# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-gpt5-goal-terminal-allocation-window-2026-03-07 | Evaluate reported post-terminal goal-flow allocation mutability and add a regression test for the treasury-resolved / stake-vault-unresolved window | `test/flows/FlowLedgerChildSyncProperties.t.sol`, `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | add regression test covering post-terminal allocation edit bypass window; no production symbol changes | Keep scope isolated to test evidence for the report; preserve unrelated dirty worktree changes | 2026-03-07 |
| codex-gpt5-zip-src-script-mode-2026-03-07 | Restore executable invocation path for `pnpm zip:src` by fixing the audit-context wrapper script mode | `scripts/package-audit-context.sh`, `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | no symbol changes; file mode only | Keep scope limited to the wrapper script and do not touch unrelated active work | 2026-03-07 |
## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

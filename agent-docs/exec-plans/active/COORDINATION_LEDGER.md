# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-gpt5-flow-bulk-remove-cutover-2026-03-04 | Hard cutover: remove `bulkRemoveRecipients` entrypoint from `Flow` | `src/Flow.sol`, `test/flows/FlowInitializationAndAccessAccess.t.sol`, `test/flows/FlowRecipients.t.sol`, `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | delete `Flow.bulkRemoveRecipients`; delete/retarget tests that call removed selector | Hard cutover with no backward-compat shim; keep recipient removal behavior via `removeRecipient` | 2026-03-04 |
| codex-gpt5-mechanism-policy-funding-pool-only-2026-03-04 | Ensure allocation-mechanism funding policy tracks only pool cumulative receipts (not raw escrow balance) so min/deadline/cap policy cannot be satisfied by temporary escrow top-ups | `src/tcr/AllocationMechanismTCR.sol`, `test/rounds/AllocationMechanismTCR.t.sol`, `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | refactor `_effectiveEscrowFunding` semantics to pool-only accounting; update direct-escrow funding tests to new policy expectations; add regression coverage for pre-deadline sync not inflating `maxEffectiveFundingObserved` from raw escrow balance | Preserve refund/release lifecycle and trusted factory allowlist behavior while removing balance-inflation policy bypass | 2026-03-04 |

## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

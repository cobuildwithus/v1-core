# Coordination Ledger (Active Only)

Use this file only for currently active coding work. Keep it minimal and current.

## Open Entries

| Agent/Session | Task | Files in Scope | Symbols (add/rename/delete) | Dependency Notes | Updated (YYYY-MM-DD) |
| --- | --- | --- | --- | --- | --- |
| codex-gpt5-roundfactory-arb-impl-cutover-2026-03-04 | Hard cutover: pass ERC20VotesArbitrator implementation into `RoundFactory` constructor instead of deploying with `new` | `src/rounds/RoundFactory.sol`, `script/DeployGoalFactory.s.sol`, `test/**`, `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` | rename constructor signature for `RoundFactory`; delete internal `new ERC20VotesArbitrator()` path/cached deploy; update constructor callsites | No backward-compat shim; update all compile-time callsites in same change set | 2026-03-04 |

## Rules

1. Add a row before your first code edit for every coding task (single-agent and multi-agent).
2. Update your row immediately when scope or symbol-change intent changes.
3. Before deleting or renaming a symbol, check this table for dependencies.
4. Delete your row as soon as the task is complete or abandoned.
5. Leave only the header and empty table when there is no active work.

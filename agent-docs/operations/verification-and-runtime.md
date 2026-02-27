# Verification and Runtime

Last verified: 2026-02-26

## Verification Commands

- Default Solidity gate (local-fast): `pnpm -s verify:required`
- CI-parity Solidity gate (includes invariants): `pnpm -s verify:required:ci`
- Optional full gate (only when requested): `pnpm -s verify:required:full`
- Serialized full gate with shared logs: `pnpm -s verify:full`
- Strict freshness full gate: `pnpm -s verify:full:strict`
- Follow active full gate logs: `pnpm -s verify:full:tail`
- Local required gate composition: `pnpm -s build` + `pnpm -s test:lite:shared`
- CI-parity gate composition: `pnpm -s build` + `pnpm -s test:lite:shared` + `FOUNDRY_PROFILE=ci pnpm -s test:invariant:shared`
- `verify:required` is queue-backed/coalesced for concurrent local agents (`scripts/verify-queue.sh submit required --wait`).

## Temporary Slither Exception

- As of 2026-02-26, Slither excludes `src/swaps/CobuildSwap.sol` in local and CI runs as a temporary risk-acceptance decision while a planned `CobuildSwap` V2 replacement is prepared.
- This exception is intentionally narrow (single file path) and should be removed once V2 lands.
- As of 2026-02-26, Slither uses `slither.db.json` for fingerprint-level triage of accepted findings (intentional quantization math, trusted-core reentrancy false positives, and explicit donor forwarding helper semantics).
- `CustomFlow` constructor hardening landed on 2026-02-26 (constructor is non-payable), so `locked-ether` no longer appears in targeted Slither runs.

## Required Checks Matrix

| Change scope | Required action | Notes |
| --- | --- | --- |
| Docs-only (`*.md`, `agent-docs/**`, no `.sol` edits) | No verification required by default | Do not run `forge build`, `pnpm -s build`, or `pnpm -s verify:required` unless explicitly requested. |
| Any `.sol` file touched | Run `pnpm -s verify:required` before handoff | Required gate. |
| User explicitly says to skip checks for this turn | Skip checks | User instruction takes precedence for that turn. |

## Shared Lanes and Scoped Iteration

- Shared build lane: `pnpm -s build` (`scripts/forge-build-shared.sh`, default `SHARED_BUILD_THREADS=0` for all logical cores).
- Multi-agent default lanes:
  - `pnpm -s test:lite:shared` (test `-j 0`, shared-build `-j 0`)
  - `pnpm -s coverage:ci:shared` (coverage `-j 4`)
- Optional compile strategy toggles for scoped experiments:
  - `TEST_SCOPE_DYNAMIC_TEST_LINKING=1` to pass `--dynamic-test-linking`.
  - `TEST_SCOPE_SPARSE_MODE=1` to enable `FOUNDRY_SPARSE_MODE=true`.
- Optional fast local iteration profile (keeps required gate unchanged):
  - `pnpm -s test:lite:fast`
  - `pnpm -s test:flows:fast`
  - `pnpm -s test:goals:fast`
- Scoped test lanes:
  - `pnpm -s test:tcr:shared`
  - `pnpm -s test:arbitrator:shared`
  - `pnpm -s test:budget:shared`
  - `pnpm -s test:flows:shared`
  - `pnpm -s test:goals:shared`
  - `pnpm -s test:invariant:shared`
- During multi-agent sessions, prefer scoped lanes while iterating and run one final `pnpm -s verify:required` before handoff.

## Multi-Agent Change Ledger

- Ledger path: `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`.
- Use the ledger for every coding task (single-agent and multi-agent). Do not skip ledger claims.
- Required per active entry:
  - agent/session identifier and short task label,
  - expected file paths,
  - symbols likely to be added, renamed, or deleted (including test harness helpers),
  - short dependency notes (for example "depends on helper X still existing"),
  - last-updated date.
- Workflow:
  - before first edit, add your row,
  - before spawning any audit/review subagent, ensure your row is present and current,
  - require spawned subagents to read the ledger and respect active ownership boundaries,
  - update your row in the same turn whenever file scope or symbol plans change,
  - before deleting/renaming a symbol, check ledger rows for dependencies and resolve conflicts first,
  - when your task is complete or abandoned, delete your row immediately.
- Keep the ledger as an active-only artifact: no historical backlog and no stale completed entries.

## Freshness Notes

- `verify:full` is one-shot snapshot semantics (no auto-rerun): if drift occurs, it logs `STALE` but preserves run result.
- Use `verify:full:strict` when drift must fail the gate (`exit 86`).

## Runtime Guardrails

Runtime measurements below were captured on February 19, 2026 (16 logical cores) and should be treated as order-of-magnitude guidance.

- `forge build -q`: ~145s cold.
- `pnpm -s test:lite`: ~129-133s cold, ~1-2s warm (test execution is sub-second; compile dominates).
- `pnpm -s coverage:ci`: ~70-87s.
- `pnpm -s coverage:quick`: ~66-70s cold.
- `pnpm -s coverage`: ~533s (~8m53s) and highest CPU pressure locally.
- `coverage` uses the heavier `coverage` profile; observed invariant runs reached `runs: 256` / `calls: 128000`, while `coverage-ci` uses reduced limits.
- Fast local coverage feedback: use `pnpm -s coverage:quick` (skips invariant path, lowers fuzz pressure).
- Avoid running more than one `pnpm -s coverage` job at the same time on a shared machine.

## Troubleshooting

- If a command appears hung, check competing Foundry jobs first:
  - `ps -Ao pid,ppid,%cpu,etime,command | rg 'forge test|forge coverage|solc-0.8.34'`

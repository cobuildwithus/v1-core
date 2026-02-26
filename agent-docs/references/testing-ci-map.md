# Testing and CI Map

## Local Verification Baseline

- `pnpm -s verify:required`
- `pnpm -s verify:required:ci` (optional local CI parity, includes invariants)
- `bash scripts/check-agent-docs-drift.sh`
- `bash scripts/doc-gardening.sh --fail-on-issues`

## Resource-Aware Local Variants

- Shared machine test pass: `pnpm -s test:lite:shared` (default test `-j 0`, shared-build `-j 0`).
- Shared machine build pass: `pnpm -s build` (queued compile lane + workspace-fingerprint reuse).
- `test:lite` and `test:lite:shared` are now routed through `scripts/test-scope.sh all-lite` (single invariant-exclusion path).
- Fast local iteration profile (reduced compile pressure, non-gating):
  - `pnpm -s test:lite:fast`
  - `pnpm -s test:flows:fast`
  - `pnpm -s test:goals:fast`
- Optional compile strategy variants for scoped lanes:
  - `pnpm -s test:flows:shared:dynamic` (`--dynamic-test-linking` + `FOUNDRY_SPARSE_MODE=true`)
  - `pnpm -s test:goals:shared:dynamic` (`--dynamic-test-linking` + `FOUNDRY_SPARSE_MODE=true`)
- Shared machine coverage pass: `pnpm -s coverage:ci:shared` (`-j 4` thread cap).
- Queued full gate (shared log + stale detection): `pnpm -s verify:full`.
- Strict queued full gate (fails on workspace drift): `pnpm -s verify:full:strict`.
- Observe active full-gate output: `pnpm -s verify:full:tail`.
- Shared verification request queue (batched build/test receipts): `pnpm -s verify:queue:required`.
- Shared verification request queue for full gate: `pnpm -s verify:queue:full`.
- Required queue lane now includes an explicit invariant pass: `FOUNDRY_PROFILE=ci pnpm -s test:invariant:shared`.
- Shared verification queue status/worker tools: `pnpm -s verify:queue:status`, `pnpm -s verify:queue:worker`.
- Queue defaults: `VERIFY_QUEUE_BATCH_WINDOW_SECONDS=5`, `VERIFY_QUEUE_MAX_BATCH=50`, `VERIFY_QUEUE_WORKER_LANES=4`.
- Queue coalescing: duplicate pending requests for the same fingerprint are coalesced (`required` can reuse pending `required/full`; `full` reuses pending `full`).
- Worker lanes run in parallel across different fingerprints with per-lane Foundry out/cache isolation.
- Simplified aliases: `pnpm -s verify:required`, `pnpm -s verify:required:ci`, `pnpm -s verify:required:full`.
- Scoped flow-focused pass: `pnpm -s test:flows:shared`.
- Scoped goal/treasury-focused pass: `pnpm -s test:goals:shared`.
- Scoped TCR/arbitrator-focused pass: `pnpm -s test:tcr:shared`.
- Scoped arbitrator-focused pass: `pnpm -s test:arbitrator:shared`.
- Scoped budget-stack pass: `pnpm -s test:budget:shared`.
- Scoped invariant-only pass: `pnpm -s test:invariant:shared`.
- Fast local coverage feedback: `pnpm -s coverage:quick` (coverage-ci profile, no invariant path, reduced fuzz).
- Avoid concurrent `pnpm -s coverage` runs when multiple agents are active.
- Multi-agent loop recommendation: iterate on scoped lanes, then run one final required gate (`pnpm -s verify:required`) before handoff; use full gate only when explicitly requested.
- Use `pnpm -s verify:required:ci` only when CI-lane parity is explicitly needed during local work.
- If required verification is queued/running, proceed with simplify + test-coverage passes in parallel instead of waiting idle, then run completion audit on the finalized diff.
- Final handoff remains gated on green required checks after any audit-driven edits are applied.

## Runtime Notes (Measured February 19, 2026)

- `forge build -q`: ~145s cold.
- `pnpm -s test:lite`: ~129-133s cold, ~1-2s warm.
- `pnpm -s coverage:ci`: ~70-87s.
- `pnpm -s coverage:quick`: ~66-70s cold.
- `pnpm -s coverage`: ~533s (~8m53s), largest CPU sink.

## Extended Verification

- Full tests: `pnpm -s test`
- Coverage gate path: `pnpm -s test:coverage:ci`
- Static analysis (local): `pnpm -s slither` (requires slither installed)

## Workflow Coverage

- Main CI: `.github/workflows/test.yml`
- Main CI required lane includes a dedicated invariant step (`FOUNDRY_PROFILE=ci pnpm -s test:invariant:shared`) before coverage.
- Static analysis: `.github/workflows/slither.yml`
- Doc maintenance: `.github/workflows/doc-gardening.yml`
- Foundry toolchain pin (test + slither workflows): `v1.6.0-rc1`.
- Size gate policy: `scripts/build-sizes-project.sh` enforces strict EIP-170 runtime limits for all concrete project contracts (no exemption env var support).
- Coverage gate floor in CI: `COVERAGE_LINES_MIN=85`, `COVERAGE_BRANCHES_MIN=85`.
- Slither CI excludes high-noise detector classes: `incorrect-equality`, `uninitialized-local`, `unused-return`.

## Doc Enforcement Scripts

- Drift checks: `scripts/check-agent-docs-drift.sh`
- Gardening/index checks: `scripts/doc-gardening.sh`
- Plan lifecycle helpers: `scripts/open-exec-plan.sh`, `scripts/close-exec-plan.sh`

## Update Rule

If verification commands, workflows, or enforcement scripts change, update this map and `agent-docs/QUALITY_SCORE.md`.

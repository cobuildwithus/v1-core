# Testing and CI Map

## Local Verification Baseline

- `pnpm -s verify:required`
- `pnpm -s verify:required:ci` (optional local CI parity, includes invariants)
- `verify:required` is queue-backed/coalesced to reduce duplicate concurrent local runs.
- Queue `required` mode defaults to `FOUNDRY_PROFILE=default` and `TEST_SCOPE_SKIP_SHARED_BUILD=1` for a single-compile local gate path.
- Queue worker start is immediate (no batch-delay config path).
- Queue worker lane caches are lane-scoped (not fingerprint-scoped) to maximize artifact reuse across adjacent local requests.
- `bash scripts/check-agent-docs-drift.sh`
- `bash scripts/doc-gardening.sh --fail-on-issues`

## Resource-Aware Local Variants

- Shared machine test pass: `pnpm -s test:lite:shared` (default test `-j 0`, shared-build `-j 0`).
- Shared machine build pass: `pnpm -s build` (shared compile lane + workspace-fingerprint reuse).
- `test:lite` and `test:lite:shared` are now routed through `scripts/test-scope.sh all-lite` (single invariant-exclusion path).
- Fast local iteration profile shortcuts (reduced compile pressure for direct lane runs):
  - `pnpm -s test:lite:fast`
  - `pnpm -s test:flows:fast`
  - `pnpm -s test:goals:fast`
- Optional compile strategy variants for scoped lanes:
  - `pnpm -s test:flows:shared:dynamic` (`--dynamic-test-linking` + `FOUNDRY_SPARSE_MODE=true`)
  - `pnpm -s test:goals:shared:dynamic` (`--dynamic-test-linking` + `FOUNDRY_SPARSE_MODE=true`)
  - `TEST_SCOPE_SKIP_SHARED_BUILD=1 pnpm -s test:lite:shared` (skip prebuild; compile directly in test run)
- Shared machine coverage pass: `pnpm -s coverage:ci:shared` (`-j 4` thread cap).
- Serialized full gate (shared log + stale detection): `pnpm -s verify:full`.
- Strict serialized full gate (fails on workspace drift): `pnpm -s verify:full:strict`.
- Observe active full-gate output: `pnpm -s verify:full:tail`.
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
- If required verification is running, proceed with simplify + test-coverage passes in parallel instead of waiting idle, then run completion audit on the finalized diff.
- Final handoff remains gated on green required checks after any audit-driven edits are applied.

## Runtime Notes (Measured February 27, 2026)

- `forge build -q`: ~259s cold.
- `pnpm -s test:lite:shared`: ~264-269s cold, ~1.5-3.3s warm.
- Cold `test:lite:shared` runtime is nearly unchanged across `TEST_SCOPE_THREADS=0/8/4` on this host (compile-bound).
- Warm `test:lite:shared` is fastest at `TEST_SCOPE_THREADS=8` on this host.
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

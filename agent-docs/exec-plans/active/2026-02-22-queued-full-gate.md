# Queued Full Gate and Shared Logs

## Objective
- Add a single queued command for full verification so concurrent agents do not start overlapping heavy compile/test runs.

## Scope
- `scripts/verify-full-gate.sh`
- `scripts/tail-full-gate-log.sh`
- `package.json`
- `AGENTS.md`
- `agent-docs/references/testing-ci-map.md`

## Plan
1. Add a queue lock around the full verification gate (`forge build -q` then `pnpm -s test:lite:shared`).
2. Write shared active/latest log pointers so other agents can observe one running gate.
3. Detect workspace drift during a run and mark result stale unless explicitly overridden.
4. Document usage and expected workflow for multi-agent sessions.

## Verification
- `bash -n scripts/verify-full-gate.sh`
- `bash -n scripts/tail-full-gate-log.sh`
- `pnpm -s verify:full:nowait --help`
- `forge build -q`
- `pnpm -s test:lite`

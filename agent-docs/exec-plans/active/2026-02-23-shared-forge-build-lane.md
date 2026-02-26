# Shared Forge Build Lane

## Objective
- Prevent multi-agent CPU spikes by ensuring `forge build` runs in one queued lane and is reused across concurrent local runs when the workspace fingerprint is unchanged.

## Scope
- `scripts/forge-build-shared.sh`
- `scripts/test-scope.sh`
- `scripts/verify-full-gate.sh`
- `package.json`
- `AGENTS.md`
- `agent-docs/references/testing-ci-map.md`

## Plan
1. Add a repo-wide queued build helper (`scripts/forge-build-shared.sh`) with stale-lock recovery and workspace fingerprint reuse.
2. Route scoped test helper (`scripts/test-scope.sh`) through the shared build helper so test entrypoints converge on one compile lane.
3. Route full gate build step through the shared build helper so all entry points share one compile lock.
4. Update command/docs guidance for multi-agent usage.

## Verification
- `bash -n scripts/forge-build-shared.sh`
- `bash -n scripts/test-scope.sh`
- `bash -n scripts/verify-full-gate.sh`
- `forge build -q`
- `pnpm -s test:lite:shared`

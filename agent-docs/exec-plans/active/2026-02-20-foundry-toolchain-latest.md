# Foundry Toolchain Pin Update to Latest

## Objective
- Pin CI workflows to the latest Foundry release so local/CI behavior is consistent.

## Scope
- `.github/workflows/test.yml`
- `.github/workflows/slither.yml`
- `agent-docs/references/testing-ci-map.md`

## Plan
1. Resolve latest Foundry release tag from GitHub releases.
2. Update workflow toolchain pins to that tag.
3. Re-run CI-equivalent gates and capture pass/fail.
4. Record any remaining unrelated CI failures.

## Verification
- `bash scripts/check-agent-docs-drift.sh`
- `bash scripts/doc-gardening.sh --fail-on-issues`
- `git diff --exit-code -- agent-docs/generated/doc-inventory.md agent-docs/generated/doc-gardening-report.md`
- `pnpm -s prettier:check`
- `pnpm -s build:sizes`
- `pnpm -s test:coverage:ci`
- `pnpm -s slither`

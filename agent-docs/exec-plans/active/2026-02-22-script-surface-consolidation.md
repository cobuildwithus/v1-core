# Script Surface Consolidation

## Objective
- Reduce redundant local script/command surface while preserving existing workflow behavior.

## Scope
- `package.json`
- `scripts/test-scope.sh`
- `scripts/copy-sol-to-clipboard.sh` (new)
- `AGENTS.md`
- `agent-docs/references/testing-ci-map.md`

## Plan
1. Remove duplicate script aliases that map to the same behavior (`flow/flows`, `goal/goals`, redundant coverage report alias, duplicate build alias).
2. Route `test:lite` variants through `scripts/test-scope.sh` so invariant-exclusion logic has one canonical implementation path.
3. Consolidate changed Solidity clipboard scripts into one shared implementation.
4. Update docs to reflect canonical command set.

## Verification
- `bash -n scripts/test-scope.sh`
- `bash -n scripts/copy-sol-to-clipboard.sh`
- `jq -e . package.json`
- `forge build -q`
- `pnpm -s test:lite`

# 2026-02-25 Delete Unused Simplifications

## Goal

Validate each proposed deletion target is unused by production runtime/deployment paths, then remove only behavior-preserving dead code and matching test scaffolding.

## Scope

- `src/library/FlowAllocations.sol`
- `src/library/AllocationCommitment.sol`
- `src/library/AllocationSnapshot.sol`
- `src/goals/library/TreasuryFlowRateSync.sol`
- `src/library/FlowSets.sol`
- impacted tests under `test/**`

## Constraints

- Do not touch `lib/**`.
- Preserve behavior for canonical production entrypoints.
- Treat test-only usage as removable/replaceable.
- Avoid storage-layout-sensitive deletions unless explicitly confirmed.

## Plan

1. Audit all references to each deletion candidate in `src/**`, `scripts/**`, and deployment/runtime docs.
2. Confirm deployment assumption status (no live deployments) and flag any sensitive ambiguity before edits.
3. Remove safe dead symbols and helper chains; update call sites/tests as needed.
4. Run completion workflow subagent passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).
5. Run `pnpm -s verify:required` and commit.

## Verification

- `pnpm -s verify:required`
- targeted `forge test --match-path ...` during iteration as needed

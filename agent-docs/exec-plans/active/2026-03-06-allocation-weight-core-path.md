# 2026-03-06 Allocation Weight Core Path

## Goal

Remove the duplicated implicit-weight wrapper stack in the allocation apply path so the core allocation libraries operate on an explicit `newWeight`, and the post-commit pipeline receives that same committed weight without rereading it from storage.

## Scope

- `src/library/CustomFlowAllocationEngine.sol`
- `src/library/FlowAllocations.sol`
- `src/flows/CustomFlow.sol`
- `test/harness/TestableCustomFlow.sol`
- Allocation tests/harnesses that exercise the old wrapper surface

## Constraints

- Preserve allocation commit, snapshot, and unit-delta behavior exactly.
- Preserve previous-state validation semantics and fail-closed behavior.
- Keep `processAllocationForCaller` as the convenience boundary that resolves weight when the caller has not already loaded it.
- Avoid disturbing unrelated in-flight edits in `src/flows/CustomFlow.sol` and shared test harness files.

## Planned Changes

1. Remove the implicit-weight apply wrapper from `FlowAllocations`; keep one explicit-weight core apply entrypoint.
2. Remove the duplicate engine wrapper and make `_runPipeline` take `newWeight` directly.
3. Keep `processAllocationForCaller` as the convenience boundary that resolves the live strategy weight.
4. Update `CustomFlow` and tests/harnesses to call the explicit-weight engine path.
5. Add or update targeted coverage for the new call flow.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Targeted Forge tests for allocation paths if needed during iteration

## Risks

- Shared worktree overlap in `src/flows/CustomFlow.sol` and `test/harness/TestableCustomFlow.sol`
- API-surface changes may require test updates outside the obvious direct callers

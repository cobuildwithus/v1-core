# Exec Plan: Flow Bytecode Size Reduction via External Libraries

Date: 2026-02-23
Owner: Codex
Status: In Progress

## Goal
Reduce `CustomFlow` deployed/runtime bytecode below EIP-170 by shrinking inherited `Flow.sol` runtime code using external library extraction.

## Scope
- `src/Flow.sol`
- `src/library/FlowSets.sol` (new)
- `src/library/FlowPools.sol`

## Constraints
- Do not modify `lib/**`.
- Preserve `Flow` runtime behavior and access control.
- Keep `connectPool` semantics equivalent (flow remains effective caller).
- Leave unrelated local workspace edits untouched.

## Acceptance criteria
- `Flow.sol` no longer directly inlines `EnumerableSet` helpers.
- `Flow.sol` no longer directly inlines `SuperTokenV1Library.connectPool`.
- `forge build --sizes --skip test` shows `CustomFlow` under 24,576 bytes.
- `pnpm -s verify:required` passes in current workspace.

## Progress log
- 2026-02-23: Baseline size check: `CustomFlow` runtime `25,000` bytes (margin `-424`).
- 2026-02-23: Added `FlowSets` external wrappers for AddressSet operations.
- 2026-02-23: Added external `connectPool` wrapper path (later folded into `FlowPools.connectPool`; dedicated `FlowSuperfluid` library removed).
- 2026-02-23: Refactored `Flow.sol` to call `FlowSets`/`FlowPools.connectPool` and updated `_afterAllocationSet` to use stored `recipientType`.
- 2026-02-23: Post-change size check: `CustomFlow` runtime `24,225` bytes (margin `+351`).
- 2026-02-23: Post-fold size check: `CustomFlow` runtime `24,236` bytes (margin `+340`), still under EIP-170.
- 2026-02-23: Required verification gate passed: `pnpm -s verify:required`.

## Open risks
- `TestableCustomFlow` remains over EIP-170 in raw size reports; this plan only targets production `CustomFlow` runtime pressure.

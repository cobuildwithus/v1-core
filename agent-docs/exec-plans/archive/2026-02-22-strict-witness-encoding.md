# 2026-02-22 Strict Witness Encoding

## Goal
Enforce a single canonical previous-allocation witness encoding (`abi.encode(bytes32[] ids, uint32[] scaled)`) and remove witness-carried weight state from decode plumbing.

## Scope
- Update `src/library/AllocationWitness.sol` to keep only canonical witness fields.
- Update `src/flows/CustomFlow.sol` to resolve cached previous weight outside witness state.
- Update witness harness/tests that currently expect `weightUsed` in decoded witness state.

## Constraints
- Do not modify `lib/**`.
- Keep pre-deployment simplification stance (no backward-compat decoding heuristics).
- Preserve existing allocation commitment validation behavior.

## Acceptance criteria
- Witness decoding accepts only canonical `(bytes32[], uint32[])` payload shape.
- `AllocationWitness.PrevState` no longer contains `weightUsed`.
- `CustomFlow` still uses cached previous weight for ledger/checkpoint math.
- `forge build -q` and `pnpm -s test:lite` pass.

## Progress log
- 2026-02-22: Created plan and started implementation.
- 2026-02-22: Removed `weightUsed` from `AllocationWitness.PrevState`; witness decode remains canonical `(bytes32[], uint32[])`.
- 2026-02-22: Refactored `CustomFlow._decodeAndResolvePreviousState` to return `(prevState, prevWeight)` instead of mutating witness state.
- 2026-02-22: Updated witness harness/tests for the new witness state shape.
- 2026-02-22: Verification run:
  - `forge build -q` failed in `test/goals/RewardEscrowIntegration.t.sol` due existing argument-count mismatches on `syncAllocation`/`clearStaleAllocation` calls.
  - `pnpm -s test:lite` completed with 809 passing / 2 failing tests (`CustomFlowRewardEscrowCheckpoint.t.sol`, `RewardEscrow.t.sol`), both outside this change.
  - Targeted checks passed: `forge test --match-path test/flows/AllocationWitness.t.sol` and `forge test --match-path test/flows/FlowAllocationsLifecycle.t.sol`.

## Open risks
- Existing in-flight callers that still encode non-canonical witness tuples would now fail decode at runtime.

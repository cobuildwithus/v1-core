# Option C TMP Snapshot Gas Benchmark

Status: active
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Prototype a simplified Option C allocation snapshot design in temporary/test-only contracts and benchmark gas against the current witness-only `CustomFlow.allocate` path.

## Scope

- In scope:
  - Add isolated TMP benchmark contracts for packed snapshot storage variants:
    - `(bytes32 recipientId, uint32 scaled)` entries.
    - `(uint32 recipientIndex, uint32 scaled)` entries with append-only index array.
  - Add Foundry gas benchmark tests comparing:
    - current `CustomFlow.allocate` update gas,
    - TMP snapshot first-write and overwrite gas for both formats.
  - Emit reproducible benchmark logs at representative recipient counts.
- Out of scope:
  - Changing protocol runtime behavior in `src/**`.
  - Integrating snapshot storage into production allocation paths.
  - Altering `lib/**` or submodules.

## Constraints

- Keep production interfaces and behavior unchanged.
- Keep TMP logic isolated to test-only artifacts.
- Preserve canonical recipient identity externally as `bytes32` for the indexed variant.
- Required Solidity check gate before handoff: `pnpm -s verify:required`.

## Acceptance Criteria

- Benchmarks run in Foundry and report gas numbers for:
  - current allocation update path,
  - snapshot bytes32-entry path,
  - snapshot indexed-entry path.
- Indexed snapshot format demonstrates materially lower snapshot byte/slot footprint and first-write gas than bytes32-entry format at same recipient counts.
- Benchmark output explicitly reports indexed registration and overwrite gas so index-lookup overhead is visible.
- No production contract behavior changes are introduced.

## Progress log

- 2026-02-24: Plan opened.
- 2026-02-24: Added `TmpSnapshotBytes32Store` and `TmpSnapshotIndexedStore` under `test/harness/`.
- 2026-02-24: Added benchmark suite `test/flows/FlowAllocationSnapshotTmpGas.t.sol` comparing current allocate gas vs TMP snapshot write paths.
- 2026-02-24: Added unit coverage for TMP store guards, packing size/slot formulas, and benchmark input validation.
- 2026-02-24: Verified with `forge test -vv --match-path test/flows/FlowAllocationSnapshotTmpGas.t.sol` and `pnpm -s verify:required` (request ids `20260224T015343Z-pid26451-27721` and `20260224T020645Z-pid61287-21812`).
- 2026-02-24: Re-verified after completion-audit clarifications with `forge test -vv --match-path test/flows/FlowAllocationSnapshotTmpGas.t.sol` and `pnpm -s verify:required` (request id `20260224T021505Z-pid83089-28441`).

## Open risks

- Absolute gas values vary with Foundry profile and warm/cold access patterns; comparison should focus on same-test relative deltas.
- Current flow allocation benchmark includes protocol side effects beyond snapshot writes, so direct magnitude comparisons need clear labeling.

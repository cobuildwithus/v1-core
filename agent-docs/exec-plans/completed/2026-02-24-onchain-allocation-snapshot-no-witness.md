# Onchain Allocation Snapshot + No-Witness Allocation Flow

Status: completed
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Eliminate allocator-provided previous-allocation witnesses by persisting prior allocation snapshots onchain, while preserving fail-closed sync behavior and child-flow correctness.

## Scope

- In scope:
  - Replace witness-dependent allocation previous-state decode with onchain snapshot retrieval per `(strategy, allocationKey)`.
  - Add compact onchain snapshot persistence for recipient allocation vectors.
  - Keep external recipient identity as `bytes32` while enabling compact internal snapshot encoding.
  - Remove witness parameters from allocate/sync/clear interfaces and call paths.
  - Convert child sync path from witness-coverage requests to automatic parent-driven child sync on changed budget targets.
  - Trigger witnessless stale sync on stake-weight decreases in goal-stake-vault driven paths.
  - Remove temporary benchmark scaffolding after production implementation is in place.
- Out of scope:
  - `lib/**` edits.
  - Introducing backward-compatibility shims for legacy witness APIs.

## Constraints

- Preserve allocation determinism and canonical sorted+unique recipient invariants.
- Preserve fail-closed behavior for required child targets and sync execution.
- Keep storage and interface changes coherent in one compiling change set.
- Required Solidity verification gate before handoff: `pnpm -s verify:required`.

## Acceptance Criteria

- `allocate`/`syncAllocation`/`clearStaleAllocation` no longer require previous allocation witness input.
- Previous-state allocation math sources old recipient vectors from onchain snapshot storage.
- Child sync pipeline no longer requires child witness payloads and still syncs changed child targets deterministically.
- Goal stake-vault weight decreases trigger witnessless allocation resync for existing allocator commitments.
- TMP benchmark-only contracts/tests are removed.

## Progress log

- 2026-02-24: Plan opened.
- 2026-02-24: Implemented witnessless allocation/sync/clear path using stored compact snapshots and recipient indexing.
- 2026-02-24: Migrated pipeline child-sync flow to automatic target resolution (no caller witness payload).
- 2026-02-24: Updated flow test surface for witnessless semantics; added snapshot-integrity fail-closed tests.
- 2026-02-24: Removed temporary snapshot benchmark artifacts and passed `pnpm -s verify:required`.

## Open risks

- Pre-deployment migration assumptions remain strict: preexisting state without recipient indices/snapshots would require migration before enabling this logic.

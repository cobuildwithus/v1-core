# Proposal 2 Witness Helper Consolidation

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Collapse witness decode + previous-commit validation into one internal utility so allocate/sync/preview share the same deterministic behavior and fail-closed checks.

## Scope

- In scope:
  - Add shared witness helper utility returning canonical previous state (`weightUsed`, `ids`, `bps`).
  - Route `CustomFlow` allocate/sync/preview call paths through the shared helper.
  - Keep witness sorted/unique checks centralized in the helper.
  - Add focused tests for empty/non-empty decode behavior and commitment-match property behavior.
- Out of scope:
  - Any changes under `lib/**`.
  - External interface/API changes.

## Constraints

- Preserve existing external behavior and revert semantics for invalid witnesses.
- Keep commitment matching strict and deterministic.
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- `_processAllocationKey`, `_syncAllocationWithDecodedWitness`, and `previewChildSyncRequirements` consume one shared witness helper.
- Witness helper enforces sorted/unique witness IDs for non-empty witness arrays.
- Witness helper validates witness commitment against stored commit (or empty state for first-use keys).
- Tests cover decode empty vs non-empty and commitment-match vs mismatch behavior.

## Progress Log

- 2026-02-21: Drafted plan and identified current duplicated decode + validation paths in `CustomFlow` and `FlowAllocations`.
- 2026-02-21: Added `AllocationWitness` helper and routed allocation/sync/preview witness handling through centralized decode + commitment validation.
- 2026-02-21: Added focused witness helper tests and harness (`AllocationWitness.t.sol`).
- 2026-02-21: Verified with `forge build -q` and `pnpm -s test:lite` (pass).

## Open Risks

- Reordering checks can change exact revert selectors on malformed payload edge-cases; keep behavior stable where currently asserted by tests.

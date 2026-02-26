# Proposal 6 Commitment Weight Removal

Status: in_progress
Created: 2026-02-21
Updated: 2026-02-21

## Goal

- Simplify allocation commitment semantics by removing weight from commitment hashing:
  commitment becomes canonical `keccak256(abi.encode(recipientIds, allocationScaled))` while previous/new
  weight remains sourced and tracked on-chain via `allocWeightPlusOne` and strategy reads.

## Success criteria

- Core allocation paths (`allocate`, `syncAllocation`, `clearStaleAllocation`) validate witnesses against
  id/bps-only commitments.
- Child-sync witness validation uses id/bps-only commitments.
- Legacy weight-prefixed witness payloads remain accepted for decode/validation compatibility.
- Tests cover new canonical hash behavior and cache-missing failure behavior.
- Required verification commands are run and outcomes captured.

## Scope

- In scope:
- `src/library/AllocationCommitment.sol` canonical hash update.
- `src/library/AllocationWitness.sol` decode/validation update (id/bps canonical + legacy compatibility).
- `src/library/FlowAllocations.sol` and `src/flows/CustomFlow.sol` cache-truth enforcement (no witness-weight bootstrap).
- `src/library/GoalFlowLedgerMode.sol` child witness validation alignment.
- Flow-related tests and docs where commitment semantics are asserted/documented.
- Out of scope:
- Fixing unrelated compile/test failures already present in goals/TCR modules.

## Constraints

- Technical constraints:
- Do not modify `lib/**`.
- Preserve deterministic sorted/unique witness semantics.
- Keep weight as on-chain source of truth for unit math and ledger checkpointing.
- Product/process constraints:
- Treat commitment hash semantic change as intentionally breaking for consumers depending on old hash shape.
- Keep execution plan + architecture/reference docs updated.

## Risks and mitigations

1. Risk: Existing commits generated with weight-inclusive hash will no longer validate under new semantics.
   Mitigation: Explicitly treat as v2-style breaking change; update docs/tests to reflect canonical id/bps hash.
2. Risk: Legacy witness encoding incompatibility could break integrations.
   Mitigation: `AllocationWitness` decode path accepts both canonical id/bps and legacy weight-prefixed payloads.
3. Risk: Missing cached previous weight could lead to silent drift.
   Mitigation: Existing-commit paths now fail closed with `INVALID_PREV_ALLOCATION` when cache is unset.

## Tasks

1. Update commitment/witness libraries and flow allocation plumbing.
2. Align child-sync witness validation with new commitment shape.
3. Update flow tests to assert id/bps commitment semantics and new cache-missing behavior.
4. Update architecture/reference docs.
5. Run required verification and record blockers.

## Decisions

- Commitment canonical form: `hash(ids, scaled)` (weight removed from commit).
- Witness decode: support both canonical `(bytes32[] ids, uint32[] scaled)` and legacy `(uint256 weight, ids, scaled)`.
- Previous-weight cache policy: existing commit + missing `allocWeightPlusOne` now reverts (no bootstrap fallback).

## Verification

- Commands to run:
- `forge build -q`
- `pnpm -s test:lite`
- `forge build -q src/library/AllocationCommitment.sol src/library/AllocationWitness.sol src/library/FlowAllocations.sol src/flows/CustomFlow.sol src/library/GoalFlowLedgerMode.sol src/Flow.sol src/interfaces/IFlow.sol src/storage/FlowStorage.sol`
- Expected outcomes:
- Repo-wide build/test currently fail due unrelated pre-existing compile errors in goals/TCR modules.
- Targeted build for touched commitment/witness/flow files passes.

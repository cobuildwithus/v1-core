# Flow Allocation Refactor and Resolver Hardening

Status: complete
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Implement proposals 1-4 (excluding proposal 5) to reduce allocation/child-sync brittleness by centralizing treasury forwarding and commitment hashing, deduplicating allocation apply logic, and hardening child sync target key derivation.

## Scope

- In scope:
  - Add shared treasury forwarding resolver and apply in `BudgetStakeStrategy` and `GoalStakeVault`.
  - Add canonical allocation commitment hashing library and replace inline commit hashing callsites.
  - Refactor `FlowAllocations` to remove duplicated merge/delta apply logic while preserving functionality.
  - Update child sync target key derivation in `CustomFlow` to use strategy `allocationKey(account, bytes(""))` with existing fail-open unresolved semantics.
  - Add/adjust tests for forwarding resolution and allocation commitment/hash behavior.
- Out of scope:
  - Proposal 5 behavior changes.
  - Any changes under `lib/**`.

## Constraints

- No live deployments exist, so external behavior changes are acceptable.
- Keep one-hop treasury forwarding fallback semantics unless explicitly changed.
- Keep unresolved child sync target behavior fail-open (`TARGET_UNAVAILABLE`) for this pass.
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- Refactor compiles and passes baseline test suite.
- Resolver behavior remains consistent across strategy/vault callsites.
- Allocation commitment hashing uses one canonical runtime path.
- Allocation apply behavior remains equivalent across calldata and memory entrypoints under existing tests.
- Child sync target derives key from strategy call instead of hardcoded cast.

## Progress log

- 2026-02-20: Drafted plan from proposal feasibility review and user-approved risk posture.
- 2026-02-20: Added `ITreasuryForwarder` + `TreasuryResolver` and refactored `BudgetStakeStrategy`/`GoalStakeVault` to use shared one-hop forwarding resolution.
- 2026-02-20: Added `AllocationCommitment` library and replaced allocation commit/witness hashing callsites in `FlowAllocations` and `CustomFlow`.
- 2026-02-20: Deduplicated `FlowAllocations` calldata/memory apply merge engine into shared `_applyAllocationPairs` path.
- 2026-02-20: Updated `CustomFlow` child sync target resolution to derive child `allocationKey` via strategy call (`allocationKey(account, bytes(\"\"))`).
- 2026-02-20: Added test coverage for resolver fallback/forwarded-owner paths and allocation commitment parity/length checks.
- 2026-02-20: Added targeted tests for child-sync malformed witness length mismatch and strategy-derived child allocation key resolution.
- 2026-02-20: Added dedicated `TreasuryResolver` unit test suite covering EOA/missing selector/revert/zero-forward/forwarded-address behavior.
- 2026-02-20: Verified with `forge build -q` and `pnpm -s test:lite` (695/695 passing).

## Open risks

- `FlowAllocations` dedupe touches critical accounting path and may alter gas/revert surfaces.
- Any mismatch in commitment hash semantics can invalidate witness continuity.
- Child sync target resolution changes may alter when strict witness coverage is enforced.

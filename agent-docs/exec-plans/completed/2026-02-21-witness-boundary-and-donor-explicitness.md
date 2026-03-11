# Witness Boundary and Donor Explicitness

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Address two cleanup items:
1) remove duplicate commitment validation on the allocation mutate path by keeping `FlowAllocations` as the hard validation boundary;
2) restore explicit donor wiring in `TreasuryDonations` instead of implicit `msg.sender`.

## Scope

- In scope:
  - `CustomFlow` witness decode path wiring for allocation updates.
  - `TreasuryDonations` helper signature updates and treasury callsite updates.
  - Build/test verification.
- Out of scope:
  - Any changes under `lib/**`.
  - External behavior changes for existing donation entrypoints.

## Constraints

- Preserve fail-closed commitment checks on mutating allocation paths.
- Keep preview/sync validation semantics explicit and deterministic.
- Preserve direct donation behavior while making helper reusable for donor forwarding.
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- Allocation mutate path no longer validates witness commitment twice before/within apply.
- `FlowAllocations` remains the commitment-validation boundary for allocation application.
- `TreasuryDonations` no longer reads `msg.sender` internally.
- `TreasuryBase` passes explicit donor (`msg.sender`) to donation helper calls.

## Progress log

- 2026-02-21: Identified duplicate commitment validation wiring between `CustomFlow` decode helper and `FlowAllocations`.
- 2026-02-21: Patched `CustomFlow` so allocation updates skip decode-time commitment validation and rely on apply-time validation boundary.
- 2026-02-21: Patched `TreasuryDonations` to take explicit `donor` and updated `TreasuryBase` callsites to pass `msg.sender`.
- 2026-02-21: Verified with `forge build -q` and `pnpm -s test:lite` (pass).

## Open risks

- Validation timing differs between allocation vs sync paths (allocation validates at apply boundary; sync/preview still fail fast). This is intentional but should remain documented.

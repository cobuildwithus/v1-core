# Parent Child Auto Sync for Budget Stake Weight Drift

Status: complete
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Close stale child-allocation influence when parent budget stake weight changes, without requiring strict success of every child sync call in the same transaction.

## Scope

- In scope:
  - Extend `CustomFlow.allocate` with caller-supplied child sync payloads.
  - Add permissionless non-zero `syncAllocationCompact` endpoint for child flows.
  - Enforce required child-sync coverage for changed budget allocations with existing child commitments.
  - Keep child sync execution best-effort (do not revert parent allocate on child sync call failure).
  - Add regression tests for happy path, missing payload, invalid witness, and best-effort failure.
- Out of scope:
  - Re-introducing full onchain recipient/bps mirrors for every allocation key.
  - Changes under `lib/**`.

## Constraints

- Preserve witness/commitment model for flow allocations.
- Keep compatibility with existing 4-argument `allocate` entrypoint.
- Run required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Tasks

1. Implement overloaded `allocate(..., ChildSyncRequestCompact[])` in `CustomFlow`.
2. Implement child-target resolution + required coverage checks for changed budget stake deltas.
3. Add permissionless `syncAllocationCompact` endpoint for non-zero resync.
4. Add/adjust flow tests for stale/non-zero resync and parent-driven child auto-sync behavior.
5. Run required verification commands.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass, 673 tests)

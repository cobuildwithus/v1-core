# Single-Strategy Flow + Simplified Allocate Surface

Status: active
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Collapse Flow runtime assumptions to one strategy per Flow instance and expose a first-class simple allocation entrypoint for the default strategy path.

## Scope

- In scope:
  - Enforce exactly one strategy at Flow initialization.
  - Keep only simplified `ICustomFlow.allocate` that derives allocation key from the flow's single configured strategy.
  - Route `CustomFlow` core allocation path through the simplified default-strategy flow.
  - Remove legacy strategy-tagged `allocate(AllocationAction[] ...)` entrypoint and related helper surface.
  - Update tests/docs for single-strategy invariant and new allocate shape.
- Out of scope:
  - Changes under `lib/**`.
  - Removing existing sync/clear stale APIs.
  - Treasury/TCR lifecycle policy changes.

## Constraints

- Preserve commitment/witness semantics and child-sync requirement behavior.
- Preserve ledger pipeline callback ordering and fail-closed behavior.
- Keep strict initialization validation and explicit erroring on invalid strategy counts.
- Required checks for Solidity changes: `pnpm -s verify:required`.

## Acceptance Criteria

- Flow initialization reverts unless exactly one strategy is provided.
- Default allocation path no longer requires strategy-tagged action arrays.
- Legacy `allocate(AllocationAction[])` is removed from interfaces and runtime.
- Tests cover the new invariant and simplified API path.

## Risks

- Wrapper compatibility could accidentally preserve too much behavior and reduce simplification impact.
- Existing tests/helpers may still assume multi-action loops and require migration.
- Interface overload changes can introduce ambiguous callsites if helper typing is loose.

## Tasks

1. Update `IFlow`/`ICustomFlow` errors + simplified allocate interface.
2. Enforce single-strategy initialization in `FlowInitialization`.
3. Refactor `CustomFlow` allocate path to default strategy and simplify engine entrypoints.
4. Update tests/helpers impacted by single-action and single-strategy constraints.
5. Update architecture/reference docs to reflect the new allocation model.
6. Run required verification and completion workflow audits.

## Progress Log

- 2026-02-23: Plan opened.
- 2026-02-23: Added `FLOW_REQUIRES_SINGLE_STRATEGY` and introduced simplified
  `ICustomFlow.allocate(bytes prevWitness, ...)` entrypoint.
- 2026-02-23: Enforced single-strategy initialization in `FlowInitialization`.
- 2026-02-23: Refactored `CustomFlow` allocation path to default strategy and removed legacy action-based allocate.
- 2026-02-23: Updated allocation engine/helper libraries and targeted flow tests/docs for single-strategy behavior.

## Verification

- Pending.

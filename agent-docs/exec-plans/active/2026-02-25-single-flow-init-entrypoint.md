# 2026-02-25 single-flow-init-entrypoint

Status: in_progress
Created: 2026-02-25
Updated: 2026-02-25

## Goal

- Remove the dual external init surface on `CustomFlow` and keep a single explicit initializer that always includes role authorities.

## Scope

- In scope:
  - Replace external `initialize` signature with role-explicit parameters (`flowOperator`, `sweeper`).
  - Remove external `initializeWithRoles` from `CustomFlow` and `IFlow`.
  - Update internal deployment/library callers and tests to the new single initializer API.
- Out of scope:
  - Allocation behavior changes.
  - Role authorization logic changes after initialization.

## Constraints

- Preserve role semantics (`recipientAdmin`, `flowOperator`, `sweeper`) exactly as today.
- Hard cutover is allowed (no backward-compatibility shim) per repo policy (no live deployments).
- Required verification gate for Solidity edits: `pnpm -s verify:required`.

## Proposed Design

1. Keep one external initializer:
   - `initialize(...)` includes all current role parameters.
2. Remove duplicate path:
   - Delete `initializeWithRoles(...)` declaration and implementation.
3. Keep internal role-aware core:
   - Reuse `__Flow_initWithRoles(...)` for initialization internals.
4. Update all callers:
   - Child-flow deployment and tests call the single initializer.

## Verification Plan

- Run `pnpm -s verify:required`.
- Run completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Risks

- Interface cutover touches many tests/callers and can cause broad compile fallout.
- If any callers still use the removed initializer symbol, build will fail until fully migrated.

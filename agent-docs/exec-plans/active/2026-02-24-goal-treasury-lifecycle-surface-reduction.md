# Goal Treasury Lifecycle Surface Reduction

Status: completed
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Reduce `GoalTreasury` lifecycle API surface by removing redundant goal-only manual entrypoints and keeping permissionless progression centered on `sync()`.

## Scope

- In scope:
  - Remove `activate()` from `GoalTreasury` and `IGoalTreasury`.
  - Remove `closeIfDeadlinePassed()` from `GoalTreasury` and `IGoalTreasury`.
  - Keep `resolveSuccess()` for UMA resolver compatibility.
  - Update goal-focused tests/invariants/docs to use `sync()` for activation/deadline progression.
- Out of scope:
  - Budget lifecycle API changes (out of scope for this goal-focused task).
  - Any edits under `lib/**`.

## Constraints

- Preserve lifecycle semantics and permissionless liveness.
- Keep goal success finalization interoperable with `UMATreasurySuccessResolver`.
- Required verification for Solidity edits: `pnpm -s verify:required`.

## Acceptance criteria

- `IGoalTreasury` no longer exposes `activate()` or `closeIfDeadlinePassed()`.
- `GoalTreasury` no longer implements those methods.
- Goal lifecycle tests/invariants pass with `sync()`-driven activation/closure behavior.

## Progress log

- 2026-02-24: Removed `activate()` and `closeIfDeadlinePassed()` from `GoalTreasury` and `IGoalTreasury`.
- 2026-02-24: Migrated goal-path test and invariant callsites from `activate()`/`closeIfDeadlinePassed()` to `sync()`.
- 2026-02-24: Updated lifecycle docs to match reduced goal transition surface.
- 2026-02-24: Added sync-focused regression coverage for permissionless activation and deadline precedence.
- 2026-02-24: Ran simplify + coverage audit + completion audit workflow and reran `pnpm -s verify:required`.

## Open risks

- Concurrent in-flight edits exist in adjacent treasury/reward files; this change is intentionally scoped to lifecycle entrypoint reduction and proceeds on top of current worktree per user instruction.

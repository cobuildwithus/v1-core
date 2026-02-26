# Budget Treasury Lifecycle Surface Reduction

Status: completed
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Reduce `BudgetTreasury` lifecycle API surface by removing redundant manual activation and keeping permissionless progression centered on `sync()`.

## Scope

- In scope:
  - Remove `activate()` from `BudgetTreasury` and `IBudgetTreasury`.
  - Update budget-focused tests/invariants/docs to use `sync()` activation paths.
  - Preserve controller/resolver lifecycle controls (`resolveFailure`, `resolveSuccess`, `disableSuccessResolution`, `forceFlowRateToZero`).
- Out of scope:
  - Goal treasury lifecycle changes.
  - Any edits under `lib/**`.

## Constraints

- Preserve lifecycle semantics and permissionless liveness for budgets.
- Keep `BudgetTCR` removal/failure terminalization behavior unchanged.
- Required verification for Solidity edits: `pnpm -s verify:required`.

## Acceptance criteria

- `IBudgetTreasury` no longer exposes `activate()`.
- `BudgetTreasury` no longer implements `activate()`.
- Budget lifecycle tests/invariants pass with `sync()`-driven activation behavior.

## Progress log

- 2026-02-24: Mapped budget lifecycle entrypoints and confirmed `activate()` has no production caller and overlaps `sync()` funding activation path.
- 2026-02-24: Removed `activate()` from `IBudgetTreasury` and `BudgetTreasury`.
- 2026-02-24: Migrated budget lifecycle tests/invariants/callsites to `sync()` activation paths and updated budget trigger docs.
- 2026-02-24: Coverage audit added `BudgetTCR.syncBudgetTreasuries` transition tests for funded activation and unfunded expiry.
- 2026-02-24: Ran required verification workflow (`test:budget:shared`, invariant path, and `verify:required` rerun); verify queue logs include unrelated dirty-tree failures outside this scope.

## Open risks

- Concurrent in-flight edits exist in adjacent budget/flow files; this task is intentionally scoped to lifecycle entrypoint reduction and proceeds on top of current worktree per user instruction.

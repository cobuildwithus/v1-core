# Flow Role Split + Goal Treasury/Hook Clone Init

Status: in_progress
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Implement minimal-separation immutable Flow roles (`recipientAdmin`, `flowOperator`, `sweeper`) while preserving parent child-sync semantics, and migrate Goal stack deployment to clone+initialize for both `GoalTreasury` and `GoalRevnetSplitHook` (option A), avoiding constructor/nonce coupling.

## Scope

- In scope:
  - Replace manager-centric mutable authority in Flow with init-only split roles.
  - Remove runtime Flow manager reassignment surface.
  - Refactor `GoalTreasury` to initializer-based cloneable deployment.
  - Refactor `GoalRevnetSplitHook` to initializer-based cloneable deployment.
  - Rewire budget and goal deployment paths to set final authorities at init.
  - Update tests/docs for new authority/deployment semantics.
- Out of scope:
  - `lib/**` edits.
  - Non-behavioral optimization-only refactors not required by authority/deployment changes.

## Constraints

- Preserve treasury lifecycle and settlement invariants.
- Preserve budget stack activation/removal liveness.
- Keep child flow parent-sync behavior for flow-rate ops.
- Required verification for Solidity edits: `pnpm -s verify:required`.

## Acceptance criteria

- Flow no longer exposes runtime manager reassignment path.
- Flow privileged operations are split across init-only authority roles.
- `sweepSuperToken` is not callable by parent-only path unless explicitly assigned as sweeper.
- Goal stack can be deployed via clone+initialize sequence without constructor nonce prediction coupling.
- Budget stack child-flow authorities are finalized at creation (no post-deploy manager handoff).
- Updated tests cover role gating and clone-init deployment invariants.

## Progress log

- 2026-02-24: Created execution plan and scoped migration sequence.

## Open risks

- Large in-flight worktree; changes must be layered without reverting unrelated edits.
- Test surface is broad (flows/goals/tcr/invariants) and likely needs staged fixture updates.

# Witness Terminology Cleanup

Status: in_progress
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Remove stale "witness" terminology from active production paths and canonical docs now that allocation previous-state is sourced from onchain snapshots.

## Scope

- In scope:
  - Rename production helper/library symbols that still use witness naming while reading snapshot-backed state.
  - Remove dead witness-only production/test code paths that are no longer referenced.
  - Rename shared flow test helper APIs from witness vocabulary to previous-state vocabulary.
  - Update canonical architecture/product/reference docs to reflect snapshot/previous-state semantics.
- Out of scope:
  - Historical execution plans and generated inventory docs.
  - Behavior changes to allocation/commit/sync logic.

## Constraints

- Preserve protocol behavior; naming-only cleanup plus dead-code removal only.
- Keep the tree compiling in one coherent change set.
- Required Solidity verification gate before handoff: `pnpm -s verify:required`.

## Acceptance Criteria

- No production source references remain to `CustomFlowWitness`/`AllocationWitness`.
- Canonical docs describe allocation previous-state snapshots instead of caller witnesses.
- Flow test helper surface no longer uses witness naming for current allocation entrypoints.

## Progress log

- 2026-02-24: Plan opened.
- 2026-02-24: Renamed `CustomFlowWitness` to `CustomFlowPreviousState` and rewired imports/call sites.
- 2026-02-24: Removed unused `AllocationWitness` library and its dedicated harness/test files.
- 2026-02-24: Renamed shared flow test helper API from witness-oriented names to previous-state names.
- 2026-02-24: Updated canonical docs (`product-specs`, architecture, references, index, product sense) to snapshot/previous-state terminology.

## Open risks

- Historical/active execution-plan docs intentionally retain witness terminology as immutable snapshots.

# BudgetTCR Removal Finalization vs Re-Registration

Status: completed
Created: 2026-02-26
Updated: 2026-02-26

## Goal

Ensure accepted budget removals remain permissionlessly finalizable even if anyone immediately re-registers the same item payload, so removed budgets cannot keep receiving goal-flow funds by blocking `finalizeRemovedBudget`.

## Scope

- In scope:
  - Decouple `finalizeRemovedBudget` from strict `items[itemID].status == Absent` gating.
  - Add a BudgetTCR-specific guard that blocks `addItem` while removal finalization is pending for that item.
  - Add/adjust regression coverage for remove -> re-register -> finalize behavior.
- Out of scope:
  - Any `lib/**` changes.
  - Broad TCR lifecycle redesign outside this edge path.

## Constraints

- Keep `GeneralizedTCR` request/challenge/dispute mechanics intact.
- Preserve permissionless `finalizeRemovedBudget` and `retryRemovedBudgetResolution` semantics.
- Run completion workflow subagent passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).
- Run required Solidity gate: `pnpm -s verify:required`.

## Acceptance criteria

- `finalizeRemovedBudget` succeeds when pending finalization exists and stack is active, even if current item status moved from `Absent` due to re-registration.
- `addItem` reverts for an item with pending removal finalization.
- Tests cover this regression path and preserve existing expected behavior for non-pending add/remove flows.

## Progress log

- 2026-02-26: Confirmed current head still gates finalize on `Status.Absent` and allows Absent->RegistrationRequested transition via `addItem`.
- 2026-02-26: User approved implementation of safe fix set.
- 2026-02-26: Implemented `addItem` pending-removal guard + decoupled finalize status gate; completion workflow passes run and `pnpm -s verify:required` passed.

## Open risks

- Shared worktree has unrelated active edits; this change set must remain scoped to BudgetTCR/TCR plus targeted tests/docs.

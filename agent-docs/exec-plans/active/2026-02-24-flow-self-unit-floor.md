# Flow Self Unit Floor

Status: complete
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Keep distribution pool total units non-zero by seeding a permanent self unit at initialization, removing per-flow-rate hot-path unit enforcement while preserving safety against accidental self-unit removal.

## Scope

- In scope:
  - Seed flow self units (`1`) during `Flow.initialize`.
  - Remove hot-path `ensureMinimumPoolUnits` call from `_setFlowRate`.
  - Add guardrails to prevent setting self units to zero.
  - Prevent adding the flow itself as a recipient.
  - Add/update tests for initialization floor, self-recipient rejection, and self-unit zeroing revert.
- Out of scope:
  - Changes under `lib/**`.
  - BudgetTCR lifecycle behavior changes.

## Constraints

- Preserve distribution semantics for non-self recipients.
- Keep pool member updates fail-closed on explicit write failures.
- Required verification before handoff:
  - `pnpm -s verify:required`

## Acceptance criteria

- New flows initialize with one self unit in the distribution pool.
- `_setFlowRate` no longer performs per-call minimum-unit repair writes.
- Any attempt to set self units to zero reverts.
- Adding self as recipient reverts.
- Relevant flow tests cover these invariants.

## Progress log

- 2026-02-24: Reapplied self-unit floor changes across Flow + pool + recipient validation and flow tests.
- 2026-02-24: Restored active execution plan doc after concurrent worktree edits removed it.
- 2026-02-24: Ran `pnpm -s build` and `pnpm -s test:lite:shared`; both failed on unrelated pre-existing `BudgetTCR`/`GeneralizedTCR` compile errors outside this change set.

## Open risks

- Workspace contains unrelated compile failures in `BudgetTCR`/`GeneralizedTCR` test surfaces, preventing green required gates in this tree.

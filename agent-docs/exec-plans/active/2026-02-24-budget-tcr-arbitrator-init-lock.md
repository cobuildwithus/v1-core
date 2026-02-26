# Budget TCR Arbitrator Init Lock

Status: in_progress
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Make `GeneralizedTCR` / `BudgetTCR` arbitrator selection immutable after initialization, including `arbitratorExtraData`, by locking `setArbitrator` from day one.

## Scope

- In scope:
  - Remove runtime arbitrator mutability by hard-reverting `setArbitrator(...)`.
  - Add explicit immutability error surface for clear revert assertions.
  - Update tests and TCR docs that assumed arbitrator rotation.
- Out of scope:
  - Changes to other governor setters.
  - Any edits under `lib/**`.

## Constraints

- Keep deployment-time arbitrator validation unchanged in initializer.
- Preserve per-request snapshot semantics for `request.arbitrator` and `request.arbitratorExtraData`.
- Run required Solidity verification gate: `pnpm -s verify:required`.

## Acceptance criteria

- Any call to `setArbitrator(...)` reverts with an immutability error.
- `arbitrator` and `arbitratorExtraData` remain unchanged after attempted setter calls.
- Governance and timeout tests no longer rely on post-deploy arbitrator replacement.

## Progress log

- 2026-02-24: Identified mutable `setArbitrator` path and dependent tests/docs.
- 2026-02-24: Locked `setArbitrator` with explicit immutability revert and updated governance/timeout tests.
- 2026-02-24: Updated TCR docs/reference map to reflect init-only arbitrator config.

## Open risks

- Existing dirty worktree includes unrelated in-flight changes; this plan scopes only arbitrator immutability behavior.

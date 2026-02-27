# Child Default Zero Manager Reward

Status: in_progress
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Remove manager-reward stacking across flow hierarchies by making child flow creation default to `managerRewardPoolFlowRatePpm = 0` globally.

## Scope

- In scope:
  - Remove the explicit child manager reward override surface (`addFlowRecipientWithParams`).
  - Make `addFlowRecipient(...)` create child flows with zero manager reward share by default.
  - Update BudgetTCR child creation path to use the canonical `addFlowRecipient(...)` surface.
  - Update mocks/tests to reflect global zero-default child behavior.
- Out of scope:
  - Runtime mutability for child manager reward share.
  - Changes under `lib/**`.

## Constraints

- Hard cutover semantics are acceptable (no live deployments).
- Keep recipient/authority wiring semantics unchanged.
- Run required Solidity verification gate (`pnpm -s verify:required`) after edits.
- Run completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Acceptance criteria

- `addFlowRecipient(...)` initializes every child flow with `managerRewardPoolFlowRatePpm == 0`.
- `addFlowRecipientWithParams(...)` is removed from protocol surfaces.
- Budget child flows still initialize with `0%` manager reward share.

## Progress log

- 2026-02-27: Claimed scope in coordination ledger and drafted hard-cutover plan.
- 2026-02-27: Test-coverage-audit pass added regressions for removed `addFlowRecipientWithParams` selector reachability and zero-rate `FlowRecipientCreated` payload assertions.

## Open risks

- This is a global behavior change for non-budget child flows that previously inherited parent manager reward share.

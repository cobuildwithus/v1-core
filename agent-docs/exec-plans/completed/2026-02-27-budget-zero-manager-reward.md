# Budget Flow Zero Manager Reward

Status: completed
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Ensure budget child flows created by `BudgetTCR` initialize with `managerRewardPoolFlowRatePpm = 0` while preserving existing default child-flow behavior for all non-budget callers.

## Scope

- In scope:
  - Add a flow child-creation surface that accepts an explicit child manager reward share for child initialization.
  - Keep existing `addFlowRecipient(...)` semantics unchanged (inherits parent manager reward flow share).
  - Update `BudgetTCR` budget activation path to call the new surface with zero manager reward share.
  - Add/adjust tests and mocks to verify budget child flows are zero-share.
- Out of scope:
  - Any runtime mutable setter for manager reward share.
  - Changes under `lib/**`.

## Constraints

- Preserve existing `addFlowRecipient(...)` ABI and behavior.
- Maintain budget stack deployment/lifecycle invariants.
- Run required Solidity verification gate: `pnpm -s verify:required`.
- Run completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Acceptance criteria

- Budget stack activation creates child flows with `managerRewardPoolFlowRatePpm == 0`.
- Existing non-budget child flow creation continues inheriting parent `managerRewardPoolFlowRatePpm` by default.
- Required verification is rerun after completion workflow edits; unrelated failures are documented if present.

## Progress log

- 2026-02-27: Claimed task scope in `COORDINATION_LEDGER` and documented implementation plan.
- 2026-02-27: Implemented `addFlowRecipientWithParams(...)` across `IManagedFlow`/`Flow`/`CustomFlow`/`CustomFlowLibrary`; legacy `addFlowRecipient(...)` now routes through shared logic using inherited parent manager reward ppm.
- 2026-02-27: Updated `BudgetTCR` budget stack activation to call `goalFlow.addFlowRecipientWithParams(..., 0, ...)` so budget child flows initialize with zero manager reward share.
- 2026-02-27: Updated budget mocks and regression coverage (`BudgetTCR.t.sol`) to assert budget child manager reward ppm is forced to zero.
- 2026-02-27: Completion workflow passes run:
  - `simplify`: one no-op cleanup in `MockBudgetTCRSystem` (remove redundant zero-init assignment).
  - `test-coverage-audit`: added explicit override coverage in `FlowRecipients` for non-zero override and invalid-rate revert paths.
  - `task-finish-review`: clean review; no additional code edits required.
- 2026-02-27: Verification evidence:
  - Focused tests passed:
    - `forge test --match-path test/flows/FlowRecipients.t.sol --match-test addFlowRecipientWithParams -q`
    - `forge test --match-path test/BudgetTCR.t.sol --match-test forcesChildManagerRewardRateToZero -q`
  - `pnpm -s verify:required` rerun is red due unrelated in-flight suite failures outside this change path (`test/goals/GoalRevnetIntegration.t.sol` and `test/BudgetTCRDeployments.t.sol` in separate runs).

## Open risks

- Interface extension touches core flow child-deploy path; custom/mock flow implementations must expose `addFlowRecipientWithParams(...)`.
- Required gate remains blocked by unrelated in-flight suites in the shared worktree.

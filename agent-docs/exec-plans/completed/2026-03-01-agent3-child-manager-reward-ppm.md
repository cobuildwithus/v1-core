# Agent 3 Child Manager-Reward PPM Wiring

Status: completed
Created: 2026-03-01
Updated: 2026-03-01

## Goal

Implement the Agent 3 vNext handshake change so root flows can create child flows with an explicit `managerRewardPoolFlowRatePpm` instead of hardcoded zero.

## Acceptance criteria

- `IManagedFlow.addFlowRecipient` includes `uint32 managerRewardPoolFlowRatePpm` in the canonical argument order.
- `Flow.addFlowRecipient` and `_deployFlowRecipient` thread the new argument to child deployment.
- `CustomFlow._deployFlowRecipient` and `CustomFlowLibrary.deployFlowRecipient` apply the value to child `FlowParams.managerRewardPoolFlowRatePpm`.
- Existing call sites compile with explicit ppm argument (`BudgetTCR`, mocks, and flow tests).
- Regression test coverage confirms nonzero configured ppm is set on the child and manager reward pool is preserved.
- Required Solidity verification passes: `pnpm -s verify:required`.

## Scope

- In scope:
  - `src/interfaces/IManagedFlow.sol`
  - `src/Flow.sol`
  - `src/flows/CustomFlow.sol`
  - `src/library/CustomFlowLibrary.sol`
  - direct call sites impacted by signature change (`src/tcr/BudgetTCR.sol`, test call sites/mocks)
  - focused flow tests
- Out of scope:
  - premium escrow implementation
  - stake vault/router slashing changes
  - goal config plumbing (`coverageLambda`, `budgetPremiumPpm`, `budgetSlashPpm`)

## Decisions

- Keep call ordering exactly as provided in the shared handshake checklist.
- Preserve existing behavior where callers can still pass zero ppm explicitly.
- Add focused flow-recipient tests rather than broad unrelated suite rewrites.

## Progress log

- 2026-03-01: Claimed coordination ledger scope and reviewed required architecture/process docs.
- 2026-03-01: Implemented `addFlowRecipient` ppm threading across interface + flow deployment path and updated BudgetTCR/test mock call sites.
- 2026-03-01: Added/expanded flow tests for nonzero child ppm behavior and validation boundaries.
- 2026-03-01: Completion workflow passes executed (`simplify`, `test-coverage-audit`, `task-finish-review`) with one test assertion fix from review.
- 2026-03-01: Targeted flow suites passed (`FlowRecipients`, `FlowRates`, `FlowAllocationsLifecycle`, `FlowInitializationAndAccessAccess`, `FlowInitializationAndAccessSetters`, `FlowUpgrades`); required gate `pnpm -s verify:required` failed due unrelated parallel-agent regressions outside Agent 3 scope.

# Flow RecipientAdmin Rename + Child Role API Expansion

Status: in_progress
Created: 2026-02-25
Updated: 2026-02-25

## Goal

Hard-cutover Flow surface terminology from `manager` to `recipientAdmin` and expand child flow creation API to explicitly set child `recipientAdmin`, `flowOperator`, and `sweeper` at deployment time.

## Scope

- In scope:
  - Flow interfaces/storage/contracts/libraries (`src/interfaces/IFlow.sol`, `src/interfaces/IManagedFlow.sol`, `src/storage/FlowStorage.sol`, `src/Flow.sol`, `src/library/FlowInitialization.sol`, `src/library/CustomFlowLibrary.sol`, `src/library/FlowRecipients.sol`, `src/flows/CustomFlow.sol`).
  - Budget stack call-site wiring updates for expanded child creation API (`src/tcr/BudgetTCR.sol`, relevant mocks/tests).
  - Test suite updates to remove `manager` nomenclature for Flow authority and align expanded `addFlowRecipient` signature.
  - Architecture/spec docs that describe Flow authority model.
- Out of scope:
  - `lib/**`.
  - Introducing per-budget AllocationTCR behavior in this pass.

## Constraints

- Maintain existing runtime behavior for allocation logic and lifecycle semantics.
- Preserve role semantics:
  - recipient administration authority remains distinct from flow-rate and sweep authorities.
- Hard cutover allowed (no backward-compat aliases) unless required by compiler constraints.
- Required verification:
  - `pnpm -s verify:required`
  - completion workflow subagent passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Acceptance criteria

- Flow runtime/public APIs no longer use `manager` naming for recipient-admin authority.
- Child flow creation API accepts explicit `recipientAdmin`, `flowOperator`, `sweeper` and call sites are updated.
- Tests compile and pass under required gate.
- Architecture docs updated to reflect final naming/authority surface.

## Progress log

- 2026-02-25: Plan created; implementation started.

## Open risks

- Wide call-site blast radius across tests and mocks.
- Potential missed interface compatibility points in budget/goal integration tests.

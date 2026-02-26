# Proposal 1 - Flow/Goal Ledger Validation Decoupling

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Decouple generic `Flow` from goal-specific allocation-ledger wiring checks by moving non-generic validation ownership to goal-flow module boundaries (`CustomFlow` + `GoalFlowLedgerMode`).

## Scope

- In scope:
  - Simplify `Flow.setAllocationLedger` to storage/event behavior only.
  - Remove goal-specific ledger wiring helpers/imports from `Flow`.
  - Keep and verify goal-ledger validation in `CustomFlow.setAllocationLedger` via `GoalFlowLedgerMode.validateOrRevert(...)`.
  - Add focused tests for `GoalFlowLedgerMode.validateOrRevert` and `validateOrRevertView`.
  - Update architecture/reference docs to reflect new invariant ownership.
- Out of scope:
  - Any change under `lib/**`.
  - Allocation math/witness behavior changes.
  - Interface/API shape changes beyond internal module-boundary behavior.

## Constraints

- Preserve fail-closed validation behavior for goal flows.
- Preserve `CustomFlow.setAllocationLedger` revert semantics on invalid goal ledger wiring.
- Keep non-goal `Flow` behavior generic and policy-free.
- Required verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- `src/Flow.sol` no longer imports goal-domain interfaces for allocation-ledger validation.
- `Flow.setAllocationLedger` no longer performs goal-wiring checks.
- Goal-flow validation remains enforced through `CustomFlow` + `GoalFlowLedgerMode`.
- Added tests cover `GoalFlowLedgerMode.validateOrRevert` and `validateOrRevertView`.
- Required verification commands pass.

## Risks

- Non-goal `Flow` derivatives that expose `setAllocationLedger` without local validation may accept invalid ledgers.
- Regression risk in deterministic revert semantics if validation is not retained in goal-flow paths.

## Progress Log

- 2026-02-21: Plan created.
- 2026-02-21: Simplified `Flow.setAllocationLedger` to storage/event-only behavior and removed goal-domain wiring helper imports/functions from `Flow`.
- 2026-02-21: Added `GoalFlowLedgerModeValidation` tests and expanded `GoalFlowLedgerModeHarness` with direct `validate`/`validateView` entrypoints.
- 2026-02-21: Updated architecture/reference docs to state ledger validation ownership is goal-flow-only (`CustomFlow` + `GoalFlowLedgerMode`).

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass; 802 passed, 0 failed)
- Focused checks (pass):
  - `forge test -q --match-path test/flows/GoalFlowLedgerModeValidation.t.sol`
  - `forge test -q --match-path test/flows/GoalFlowLedgerModeParity.t.sol`

# Proposal 2 - CustomFlow Ledger-Mode Error Dedup

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Remove duplicated, unused ledger-mode custom errors from `CustomFlow` and keep ledger-mode error ownership in `GoalFlowLedgerMode`.

## Scope

- In scope:
  - Delete unused duplicated error declarations from `src/flows/CustomFlow.sol`:
    - `INVALID_ALLOCATION_LEDGER_STRATEGY`
    - `CHILD_SYNC_REQUEST_MISSING`
    - `CHILD_SYNC_REQUEST_DUPLICATE`
    - `CHILD_SYNC_INVALID_WITNESS`
    - `INVALID_ALLOCATION_LEDGER_ACCOUNT_RESOLVER`
  - Update tests that referenced `CustomFlow` selectors to reference `GoalFlowLedgerMode` selectors instead.
- Out of scope:
  - Runtime behavior changes in allocation/ledger-mode logic.
  - Any changes under `lib/**`.

## Constraints

- Preserve revert behavior and selectors emitted at runtime.
- Keep all existing tests green.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress Log

- 2026-02-21: Removed duplicated/unused ledger-mode errors from `CustomFlow`.
- 2026-02-21: Repointed affected tests to `GoalFlowLedgerMode` selectors.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass; 802 passed, 0 failed)

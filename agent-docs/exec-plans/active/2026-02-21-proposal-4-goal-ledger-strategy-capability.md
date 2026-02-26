# Proposal 4 - Explicit Goal-Ledger Strategy Capability

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Make goal-ledger-mode strategy coupling explicit by introducing a single capability interface and using it in ledger-mode validation.

## Scope

- In scope:
  - Add `src/interfaces/IGoalLedgerStrategy.sol` as:
    - `IAllocationStrategy`
    - `IAllocationKeyAccountResolver`
    - `IHasStakeVault`
  - Refactor `GoalFlowLedgerMode` strategy validation to use `IGoalLedgerStrategy` capability casting.
  - Keep empty-aux probe behavior as an explicit validation requirement.
  - Add focused validation test coverage for missing capability behavior.
  - Update architecture/reference docs for the new interface boundary.
- Out of scope:
  - ERC165/supportsInterface requirements.
  - Hard migration requiring all strategies to explicitly declare the new interface.
  - Changes under `lib/**`.

## Constraints

- Preserve existing revert selectors and fail-closed behavior.
- Preserve existing ledger-mode runtime behavior.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress Log

- 2026-02-21: Added `IGoalLedgerStrategy` capability interface.
- 2026-02-21: Refactored `GoalFlowLedgerMode` validation checks to use a single `IGoalLedgerStrategy` cast.
- 2026-02-21: Added `GoalFlowLedgerModeValidation` coverage for strategy missing `stakeVault()` capability.
- 2026-02-21: Kept strategy contracts backward-compatible (did not require them to explicitly inherit `IGoalLedgerStrategy`).

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass; 803 passed, 0 failed)

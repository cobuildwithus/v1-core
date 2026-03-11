# TreasuryBase Donation Entrypoints

Status: completed
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Centralize external donation entrypoints in `TreasuryBase` so `GoalTreasury` and `BudgetTreasury` no longer duplicate thin wrappers around shared donation internals.

## Scope

- In scope:
  - Add `donateSuperToken(uint256)` and `donateUnderlyingAndUpgrade(uint256)` as external `nonReentrant` entrypoints in `TreasuryBase`.
  - Remove duplicate wrapper implementations from `GoalTreasury` and `BudgetTreasury`.
- Out of scope:
  - Any donation policy changes (`_canAcceptDonation`, `_afterDonation`, `_revertInvalidState`).
  - Any changes under `lib/**`.

## Constraints

- Preserve existing donation behavior and event semantics.
- Keep treasury-specific policy and accounting in leaf hooks.
- Required verification for Solidity edits: `pnpm -s verify:required`.

## Acceptance criteria

- Both treasuries inherit donation entrypoints from `TreasuryBase`.
- Donation calls remain reentrancy-guarded at the external boundary.
- Existing tests pass with no behavior changes.

## Progress log

- 2026-02-23: Drafted plan and identified duplicate wrappers in `GoalTreasury` and `BudgetTreasury`.
- 2026-02-23: Moved external donation wrappers to `TreasuryBase` and removed duplicate leaf wrappers.
- 2026-02-23: Added shared `ITreasuryDonations` interface so both treasury interfaces inherit donation entrypoints and `TreasuryBase` implements a single canonical surface without override conflicts.
- 2026-02-23: Added targeted reentrancy regression tests for centralized donation wrappers in `test/goals/GoalTreasury.t.sol` and `test/goals/BudgetTreasury.t.sol`.
- 2026-02-23: Verification complete (`forge build -q`, `pnpm -s test:goals:shared`, `pnpm -s verify:required`), plus completion audit with no findings.

## Open risks

- None expected; change is interface-location refactor with existing internal donation logic unchanged.

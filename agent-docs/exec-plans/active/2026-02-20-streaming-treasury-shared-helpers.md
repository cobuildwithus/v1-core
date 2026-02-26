# Streaming Treasury Shared Helpers

Status: completed
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Reduce duplication between `GoalTreasury` and `BudgetTreasury` by extracting shared donation and flow-rate synchronization scaffolding into internal libraries while preserving external behavior.

## Scope

- In scope:
  - Add `src/goals/library/TreasuryDonations.sol` for shared donation handling:
    - SuperToken direct donation
    - underlying token transfer + upgrade + forward flow donation
  - Add a small shared flow-rate apply helper for capped flow-rate syncing.
  - Refactor `GoalTreasury` and `BudgetTreasury` to use these helpers.
  - Keep state machines, settlement, and finalize semantics contract-local.
  - Add/update tests if behavior surface changes.
- Out of scope:
  - Shared terminalization/settlement extraction.
  - Changes under `lib/**`.

## Constraints

- Preserve existing access control and state gating semantics.
- Preserve event payload semantics and accounting (`totalRaised` goal-only).
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- No functional regressions in goal/budget donation paths.
- No functional regressions in flow-rate sync application.
- Full compile + lite suite pass.

## Progress log

- 2026-02-20: Plan drafted.
- 2026-02-20: Added `TreasuryDonations` + `TreasuryFlowRateSync` libraries and refactored `GoalTreasury` + `BudgetTreasury` call-sites.
- 2026-02-20: Added treasury helper regression coverage for fee-on-transfer super-token balance-delta accounting and no-op flow-rate write behavior.
- 2026-02-20: Verification complete:
  - `forge build -q` ✅
  - `pnpm -s test:lite` ✅ (712 passed, 0 failed)

## Open risks

- Subtle revert-surface or balance-delta changes in donation paths.
- Event emission ordering changes if helper abstractions are not carefully preserved.

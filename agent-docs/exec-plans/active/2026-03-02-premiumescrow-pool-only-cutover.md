# PremiumEscrow Pool-Only Cutover (2026-03-02)

## Goal

Remove legacy `PremiumEscrow` balance-delta premium accounting and operate only on manager-reward distribution pool receipts.

## Scope

- `src/goals/PremiumEscrow.sol`
- `src/tcr/BudgetTCR.sol`
- `src/tcr/interfaces/IBudgetTCR.sol`
- impacted tests under `test/**`

## Constraints

- Preserve underwriting slash lifecycle invariants.
- Preserve Pattern B success-only premium claims.
- No `lib/**` edits.

## Plan

1. Remove `PremiumEscrow` balance-mode state/branches and require manager-reward-pool accounting path.
2. Make budget stack activation fail-closed when child manager reward distribution pool is missing.
3. Update tests/mocks to reflect pool-only behavior.
4. Run required completion workflow passes and Solidity verification gate.

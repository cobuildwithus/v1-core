# Removed Budget Cutoff + Arbitrator Upfront Validation

## Objective
- Ensure removed budgets no longer accrue reward points and no longer block success-reward readiness.
- Ensure removed budgets are excluded from success reward eligibility at finalize.
- Enforce stake-vault slash-recipient compatibility at arbitrator stake-vault configuration time.

## Scope
- `src/goals/BudgetStakeLedger.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `test/goals/BudgetStakeLedgerRegistration.t.sol`
- `test/goals/RewardEscrow.t.sol`
- `test/ERC20VotesArbitratorStakeVaultMode.t.sol`

## Plan
1. Add ledger removal timestamp semantics and apply cutoffs in checkpoint/finalize/user preview paths.
2. Treat removed tracked budgets as resolved for readiness checks.
3. Exclude removed budgets from finalize success inclusion.
4. Add upfront nonzero rewardEscrow validation in arbitrator `_setStakeVault`.
5. Add regression tests for removed-budget behavior and arbitrator validation.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

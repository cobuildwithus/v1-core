# Correctness-Over-Liveness Hardening (Child Sync + Budget Ledger)

## Objective
- Shift selected core sync/accounting paths from best-effort behavior to fail-closed behavior.
- Remove silent reconciliation in budget stake accounting so drift is surfaced immediately.
- Reduce silent authorization fallback behavior in goal stake vault treasury authority resolution.

## Scope
- `src/library/FlowRates.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/GoalStakeVault.sol`
- `src/interfaces/IBudgetStakeLedger.sol`
- `src/interfaces/IGoalStakeVault.sol`
- `test/flows/FlowChildSyncBehavior.t.sol`
- `test/goals/BudgetStakeLedgerEconomics.t.sol`
- `test/goals/GoalStakeVault.t.sol`

## Design Notes
- Child flow-rate sync failures in mutate calls (`decreaseFlowRate`, `increaseFlowRate`) now revert explicitly instead of silently requeueing.
- Budget ledger checkpointing reverts on stored-vs-expected allocation drift instead of reconciling and saturating totals.
- Goal stake vault treasury authority lookup requires explicit, non-silent authority resolution on controller-gated paths.

## Verification
- `forge build -q`
- `forge test --match-path test/flows/FlowChildSyncBehavior.t.sol`
- `forge test --match-path test/goals/BudgetStakeLedgerEconomics.t.sol`
- `forge test --match-path test/goals/GoalStakeVault.t.sol`
- `pnpm -s test:lite`

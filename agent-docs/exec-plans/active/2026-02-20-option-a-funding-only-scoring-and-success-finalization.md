# Option A: Funding-Only Budget Scoring + Immediate Success Reward Finalization

## Goal
Adopt Option A end-to-end so budget stake-time points accrue only during each budget funding window, success signaling cannot occur before funding close, and goal success reward finalization no longer waits on tracked budget resolution.

## Scope
- `BudgetStakeLedger`: store per-budget exogenous score cutoff (`fundingDeadline`) and use it for checkpoint/finalize/user cutoff paths.
- `BudgetTreasury`: enforce `resolveSuccess` funding-window gate.
- `GoalTreasury`: finalize success rewards immediately on goal success (no pending/grace hostage coupling).
- Goal/budget/reward tests and docs reflecting new invariants.

## Invariants to preserve
- Points accrual cutoff is exogenous (not controlled by discretionary success timing).
- No retroactive credit when score cutoff extends beyond budget `resolvedAt`.
- Failed/Expired finalization behavior remains unchanged.
- Reward escrow snapshots still use goal success timestamp for goal-level finalization timestamping.

## Validation
- `forge build -q`
- `pnpm -s test:lite`
- Targeted suites: `test/goals/BudgetTreasury.t.sol`, `test/goals/GoalTreasury.t.sol`, `test/goals/RewardEscrow*.t.sol`, `test/goals/RewardEscrowIntegration.t.sol`.

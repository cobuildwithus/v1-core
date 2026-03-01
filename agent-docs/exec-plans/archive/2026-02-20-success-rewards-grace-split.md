# Goal Success / Reward Finalization Split (7d Grace)

## Goal
Allow `GoalTreasury` to mark success immediately (unlocking stake withdrawals and stopping flow) while deferring reward finalization until either all tracked budgets resolve or a 7-day grace window elapses from success time.

## Scope
- `GoalTreasury`: split success from reward finalization, add pending/finalize helpers, permissionless finalize function.
- `RewardEscrow` + `BudgetStakeLedger`: accept explicit frozen success timestamp for finalization cutoff.
- Interfaces/tests updated accordingly.

## Invariants to preserve
- Early success remains meaningful (state transition + vault resolved + flow stopped + residual settlement).
- Reward points are frozen at success timestamp (not delayed finalization timestamp).
- Permissionless finalization after readiness and after grace fallback.
- No behavior change for Failed/Expired finalization paths.

## Validation
- `forge build -q`
- `pnpm -s test:lite`
- Targeted success-pending tests in `GoalTreasury` suite.

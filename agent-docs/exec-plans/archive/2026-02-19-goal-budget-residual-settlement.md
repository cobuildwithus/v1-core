# Goal + Budget Residual Settlement and Burn Policy

## Objective
- Settle leftover SuperToken balances held in budget/goal flows instead of leaving funds stranded.
- On goal success, split settled residual by treasury-specific BPS: reward escrow share + controller burn share.
- On goal failure/expiry, burn 100% of settled residual.
- Prevent goal-success finalization until all reward-eligible tracked budgets are resolved.

## Scope
- `src/Flow.sol`
- `src/interfaces/IFlow.sol`
- `src/interfaces/IManagedFlow.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/interfaces/IBudgetTreasury.sol`
- `src/interfaces/IGoalTreasury.sol`
- `src/goals/RewardEscrow.sol`
- `src/interfaces/IRewardEscrow.sol`
- goal/budget treasury + integration tests
- architecture/spec docs touching funds flow and lifecycle invariants

## Design Notes
- Add explicit Flow primitive to transfer held SuperToken balance under owner/parent/manager control.
- Budget finalize path sweeps residual child-flow balance to parent goal flow.
- Goal finalize path:
  - stop goal flow rate,
  - settle residual goal-flow balance,
  - success: reward escrow share + controller burn complement,
  - fail/expire: controller burn all,
  - then finalize reward escrow and mark vault resolved.
- Success finalization requires all tracked budgets in RewardEscrow resolved (prevents snapshot timing exclusion).

## Verification
- `forge build -q`
- `pnpm -s test:lite`

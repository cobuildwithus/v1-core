# Goal Rent Accrual + Escrow Distribution

## Objective
- Implement always-on rent charging for goal stake on both goal token and cobuild token.
- Route collected rent into `RewardEscrow`.
- Distribute rent using existing successful-budget stake-time points via `claim`.

## Scope
- `src/goals/GoalStakeVault.sol`
- `src/interfaces/IGoalStakeVault.sol`
- `src/goals/RewardEscrow.sol`
- `src/interfaces/IRewardEscrow.sol`
- `src/tcr/library/BudgetTCRDeployments.sol`
- `test/goals/helpers/GoalRevnetFixtureBase.t.sol`
- `test/goals/GoalStakeVault.t.sol`
- `test/goals/RewardEscrow.t.sol`
- `test/goals/RewardEscrowIntegration.t.sol`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/references/goal-funding-and-reward-map.md`

## Design Notes
- Rent accrues lazily per user and is capped at `goalResolvedAt`.
- Rent is collected by withholding from withdraw principal (no insolvency reverts).
- Full exits clear residual pending rent debt that cannot be collected beyond principal.
- Budget unresolved-at-finalize continues to count as failed.
- `RewardEscrow.claim` remains the single user entrypoint and now includes indexed rent distribution.
- `RewardEscrow.claim` and `sweepFailed` auto-unwrap late-arriving goal supertokens.
- `sweepFailed` allows success-state sweep only when `totalPointsSnapshot == 0` (no winner set).
- `GoalTreasury.sweepFailedRewards(to)` forwards escrow sweeps for owner-managed recovery.
- Goal-flow reward checkpointing hard-enforces strategy weight == stake-vault weight.

## Verification
- `forge build -q`
- `pnpm -s test:lite`
- `forge test --match-path test/invariant/RewardEscrow.invariant.t.sol`

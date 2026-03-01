# Reward Escrow SuperToken Normalization + Dual-Pool Snapshot

## Objective
- Normalize manager-reward SuperToken inflows into plain goal-token balances at reward finalization.
- Add permissionless unwrap helpers for ops/maintenance.
- Preserve successful-budget stake-time payouts while introducing optional secondary cobuild-token pool payout plumbing.

## Scope
- `src/goals/RewardEscrow.sol`
- `src/interfaces/IRewardEscrow.sol`
- `test/goals/helpers/GoalRevnetFixtureBase.t.sol`
- `test/goals/RewardEscrowIntegration.t.sol`
- `test/goals/RewardEscrowSweepLockExploit.t.sol`
- `test/goals/RewardEscrow.t.sol`
- `test/invariant/RewardEscrow.invariant.t.sol`
- docs references under `agent-docs/`

## Design Notes
- Manager reward streams are SuperToken-denominated; escrow snapshots are taken after optional unwrap to reward token.
- Unwrap functions are permissionless and bounded by escrow-held SuperToken balance.
- Secondary cobuild pool is optional and only active when stake vault exposes a cobuild token and escrow is funded in that token.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

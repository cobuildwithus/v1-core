# Arbitrator Slash Winner Payout (StakeVault Mode)

Status: active
Created: 2026-03-01
Updated: 2026-03-01

## Goal

Implement the agreed arbitration-economic cutover in stake-vault mode:
- keep absent-vote penalties,
- pay reveal winners from slashed loser stake (goal + cobuild),
- route no-winner rounds to `invalidRoundRewardsSink`,
- keep a single voter claim entrypoint,
- add a batch slashing helper.

## Acceptance criteria

- `slashVoter` keeps current missed-reveal/wrong-vote slash eligibility semantics.
- Slash caller bounty remains unchanged.
- Slash remainder routes:
  - winner rounds -> per-round slash pools on arbitrator (goal + cobuild accounting),
  - no-winner rounds (tie/zero revealers) -> `invalidRoundRewardsSink`.
- Arbitrator exposes `slashVoters(disputeId, round, voters[])`.
- `withdrawVoterRewards` remains the single claim entrypoint and pays:
  - one-time arbitration-cost reward share (existing behavior),
  - cumulative slash reward deltas in goal/cobuild for winner rounds.
- Tests cover routing, batch behavior, cumulative claim behavior, and no-winner sink behavior.
- Required Solidity gate passes: `pnpm -s verify:required`.

## Scope

- In scope:
  - `src/tcr/ERC20VotesArbitrator.sol`
  - `src/tcr/storage/ArbitratorStorageV1.sol`
  - `src/tcr/interfaces/IERC20VotesArbitrator.sol`
  - `test/ERC20VotesArbitratorStakeVaultMode.t.sol`
  - `test/ERC20VotesArbitratorRewards.t.sol`
- Out of scope:
  - premium/insured-streaming implementation
  - full RewardEscrow removal or GoalTreasury reward-surface cutover
  - non-stake-vault token-votes economics redesign

## Decisions

- No-winner rounds are defined as `winningChoice == 0` and use sink routing for slash remainder.
- `invalidRoundRewardsSink` is reused as the no-winner slash remainder sink.
- Single claim UX is preserved by extending `withdrawVoterRewards` with cumulative slash-delta payouts.
- Batch helper loops over existing single-voter slash logic; no separate batch-specific slash math.

## Progress log

- 2026-03-01: Claimed scope in `COORDINATION_LEDGER` and mapped arbitrator/vault/treasury/TCR + test call paths.
- 2026-03-01: Simplify pass: de-duplicated arbitration/slash reward math helpers, tightened `slashVoters` loop control flow, and aligned stale stake-vault recipient assertions with current slash routing; focused arbitrator/evidence-timeout test suites pass.

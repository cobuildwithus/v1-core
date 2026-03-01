# Juror Stake Vault Arbitration

Status: active
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Implement vault-native juror staking and slashing so arbitration voting power comes from locked `GoalStakeVault` weight (goal + cobuild), while arbitration costs/rewards continue using the configured ERC20 voting token.

## Success criteria

- `GoalStakeVault` supports juror lock lifecycle (opt-in, delayed exit, delegation, snapshots, slashing hook).
- Juror voting power snapshots are queryable by block number and used by arbitrator vote checks.
- `ERC20VotesArbitrator` supports stake-vault-backed voting mode, delegated commit, and permissionless per-voter slashing after solved rounds.
- Slashing removes locked stake proportionally across locked goal/cobuild and routes slashed funds to goal reward escrow.
- `BudgetTCRFactory` initializes arbitrator with stake-vault-backed voting mode for new deployments.
- `forge build -q` passes.
- `pnpm -s test:lite` passes (or any pre-existing unrelated failure is explicitly noted).

## Scope

- In scope:
- `src/interfaces/IGoalStakeVault.sol`
- `src/goals/GoalStakeVault.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `src/tcr/storage/ArbitratorStorageV2.sol` (new)
- `src/tcr/BudgetTCRFactory.sol`
- `test/goals/GoalStakeVault.t.sol`
- `test/ERC20VotesArbitrator*.t.sol` (targeted extensions for stake-vault mode/slashing/delegation)
- Architecture/reference docs impacted by arbitration + vault behavior changes.
- Out of scope:
- Existing onchain deployment backward compatibility/migrations.
- Changes under `lib/**`.
- Slashed-fund redistribution logic beyond direct transfer to reward escrow.

## Constraints

- Technical constraints:
- Preserve existing ERC20Votes-only arbitrator behavior when stake-vault mode is not configured (test compatibility).
- Keep security checks explicit on slashing and lock-withdraw paths.
- Keep upgradeable arbitrator storage extension append-only.
- Product/process constraints:
- For this multi-file/high-risk change, keep this execution plan updated.
- Run required verification commands before handoff.

## Risks and mitigations

1. Risk: Juror lock accounting diverges from core stake/weight accounting.
   Mitigation: Keep lock deltas explicit, clamp lock-weight on weight reductions, and add dedicated tests for edge cases.
2. Risk: Permissionless slashing introduces theft vector.
   Mitigation: Keep vault slash callable only by configured `jurorSlasher`; make permissionless entrypoint live in arbitrator where round/ruling checks are enforced.
3. Risk: Factory/arbitrator wiring mismatch leaves slashing inert.
   Mitigation: Initialize arbitrator with stake vault during deployment and require explicit one-time vault slasher setup by treasury owner.

## Tasks

1. Extend `IGoalStakeVault` with juror lock/delegate/snapshot/slashing interface.
2. Implement juror lock + delayed exit + snapshot + slashing in `GoalStakeVault`.
3. Add arbitrator storage extension for stake-vault mode and slashing processing tracking.
4. Extend `ERC20VotesArbitrator` with optional stake-vault vote source, delegated commit, and permissionless `slashVoter`.
5. Update `BudgetTCRFactory` to initialize arbitrator with goal stake vault.
6. Add/extend tests for vault juror lifecycle and arbitrator stake-vault mode.
7. Update architecture/reference docs and run verification.

## Decisions

- Voting power source in juror mode: locked vault weight snapshots.
- Juror lock assets: both goal and cobuild stakes.
- Juror exit delay: 7 days.
- Withdrawals: blocked against locked juror balances.
- Slashing: permissionless arbitrator entrypoint, 10 bps for incorrect and missed reveal.
- Slash distribution: transfer slashed stake to goal reward escrow.

## Verification

- Commands to run:
- `forge build -q`
- `pnpm -s test:lite`
- Expected outcomes:
- Build succeeds.
- Lite test suite succeeds, or any pre-existing unrelated failure is documented.

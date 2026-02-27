# Known design-intent edge cases and accepted-risk semantics

This file captures protocol-level behaviors that are easy to misread and intentionally accepted in current architecture.

## TCR and arbitration

- In stake-vault-based arbitration, `ERC20VotesArbitrator.slashVoter` treats an uncommitted juror as “missed reveal” because `missedReveal` is computed from `!receipt.hasRevealed` alone.
  - A permissionless `slashVoter` call can therefore punish non-participants that have zero-value receipts in solved rounds.
  - `src/tcr/ERC20VotesArbitrator.sol` (arbitration slashing path).

## Lifecycle and state-machine semantics

- Goal treasury terminal states are `Succeeded` and `Expired`; there is no goal-level `Failed` terminal state or manual failure entrypoint.
- Goal success finalization does not require all budgets to be resolved before treasury success state.
  - Point-accrual cutoff snapshots are anchored at the goal success timestamp, while budget reward eligibility is evaluated from terminal budget outcome (not `resolvedAt <= successAt`).
- Budget success can be permanently disabled on accepted pre-activation removal; activation-locked removals preserve success-resolution eligibility.
- Direct flow balance can satisfy activation thresholds even without hook funding telemetry.
- Child-allocation pipeline failures are observable but non-fatal to parent allocation maintenance.

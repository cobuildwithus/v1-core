# Known design-intent edge cases and accepted-risk semantics

This file captures protocol-level behaviors that are easy to misread and intentionally accepted in current architecture.

## TCR and arbitration

- Stake-vault arbitration intentionally penalizes abstention, not only failed reveal after commit:
  - `ERC20VotesArbitrator._slashVoter` computes `missedReveal` from `!receipt.hasRevealed`, so both non-reveal and never-committed voters are slash-eligible after round resolution.
  - `slashVoter`/`slashVoters` are permissionless by design, so any caller may execute that slash path for snapshot-eligible jurors in solved rounds.
  - This repository treats that behavior as accepted protocol intent (not a bug) for the current design.
  - `src/tcr/ERC20VotesArbitrator.sol` (arbitration slashing path; around `_slashVoter`).

## Lifecycle and state-machine semantics

- Goal treasury terminal states are `Succeeded` and `Expired`; there is no goal-level `Failed` terminal state or manual failure entrypoint.
- Goal success finalization does not require all budgets to be resolved before treasury success state.
  - Point-accrual cutoff snapshots are anchored at the goal success timestamp, while budget reward eligibility is evaluated from terminal budget outcome (not `resolvedAt <= successAt`).
- Accepted open-preset budget delistings are activation-gated by design, not treated as one uniform "removed means failed" rule.
  - pre-activation delistings disable budget success resolution and strict-finalize to `Failed`.
  - activation-locked delistings are detach/de-list semantics: removal stops new parent funding, zeroes forward spend, and leaves already received funds to resolve through normal `Succeeded` / `Failed` / `Expired` paths.
  - underwriter principal slash remains activation-gated, so never-activated budgets lose upside only while activated budgets remain slashable only if they later close `Failed` or `Expired`.
- Direct flow balance can satisfy activation thresholds even without hook funding telemetry.
- Child-allocation pipeline failures are observable but non-fatal to parent allocation maintenance.

# Stake-Once Budget-Scoped Arbitrator Refactor

Status: completed
Created: 2026-02-27
Updated: 2026-02-27

## Goal

- Keep stake custody only at the goal-level `StakeVault` (remove per-budget stake vaults).
- Support budget-scoped juror voting/slashing using historical budget allocation stake snapshots.
- Keep one arbitrator type (`ERC20VotesArbitrator`) with optional fixed budget scope per instance.
- Preserve stake-vault set-once slasher posture while allowing multiple arbitrators to slash via a router.

## Scope

- In scope:
  - Remove per-budget stake vault fields/wiring from budget treasury + budget stack deploy flow.
  - Add historical block snapshot reads to `BudgetStakeLedger` and interface.
  - Add optional fixed budget context in arbitrator initialization/storage and apply in vote/slash math.
  - Add `JurorSlasherRouter` and `IJurorSlasher`; wire factory authorization through router.
  - Update affected tests for interface/event/storage cutover and new voting/slashing behavior.
- Out of scope:
  - `lib/**`
  - New per-budget mechanism TCR factory implementation (future follow-up)

## Success criteria

- `IBudgetTreasury.BudgetConfig` no longer carries `stakeVault`; budget stack no longer deploys budget stake vaults.
- `BudgetStakeLedger` exposes past snapshot reads needed by arbitrator at dispute creation block.
- Arbitrator in stake-vault mode computes:
  - global mode: `pastJurorWeight`
  - budget-scoped mode: `min(pastJurorWeight, pastAllocatedStakeOnFixedBudget)`
- Slashing routes through stake vault configured slasher, supporting router-authorized arbitrators.
- `extraData` remains for arbitration cost snapshot only (no budget context encoding required).
- Required Solidity gate passes (`pnpm -s verify:required`).
- Completion workflow passes run (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Notes

- Hard cutover is accepted for this turn (no live deployments).
- Keep unrelated dirty worktree edits intact.

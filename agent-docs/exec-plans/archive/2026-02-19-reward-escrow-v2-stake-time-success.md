# Goal

Implement RewardEscrow v2 so rewards are gated on goal success and distributed using stake-time on successful budgets only.

Success criteria:
- Reward claims redeem only when goal state is `Succeeded`.
- User entitlement is derived from time-integrated budget allocations (`stake * time`) and only for budgets that resolved `Succeeded` by goal finalization.
- Failed/expired/unresolved budgets contribute zero reward points.
- Existing funds flow safety and finalize ordering remain intact.

# Scope

In scope:
- Add budget resolution timestamp surface (`resolvedAt`) to budget treasury interface/contract.
- Extend reward escrow accounting model from final-weight snapshot to checkpointed stake-time points.
- Add allocation checkpoint hook from `CustomFlow.allocate` into `RewardEscrow`.
- Update reward escrow unit/integration/invariant tests and goal fixture wiring.

Out of scope:
- Transferable claim token (secondary market) implementation.
- Oracle dispute-window freeze of point accrual.
- Any `lib/**` modification.

# Constraints

- Work on top of existing dirty branch state.
- Keep changes local to protocol + tests in this repo.
- Preserve GoalTreasury finalize semantics: stop flow, finalize escrow, resolve stake vault.

# Design Notes

- `RewardEscrow` tracks per-user-per-budget and per-budget global checkpoint state:
  - allocated stake,
  - accrued points,
  - last checkpoint timestamp.
- `CustomFlow` notifies escrow after each successful allocation key application.
- Escrow only accepts checkpoints from the goal flow and only for recognized budget treasuries under that goal flow.
- On goal finalize success, escrow snapshots:
  - reward pool,
  - finalization timestamp,
  - total successful points.
- `claim(to)` computes user points across tracked successful budgets and redeems pro-rata.

# Files Expected To Change

- `src/interfaces/IRewardEscrow.sol`
- `src/goals/RewardEscrow.sol`
- `src/interfaces/IBudgetTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/flows/CustomFlow.sol`
- `test/goals/helpers/GoalRevnetFixtureBase.t.sol`
- `test/goals/RewardEscrow.t.sol`
- `test/goals/RewardEscrowIntegration.t.sol`
- `test/invariant/RewardEscrow.invariant.t.sol`
- (if required by compile) related goal tests/mocks touching reward escrow interface

# Verification

- `forge build -q`
- `pnpm -s test:lite`

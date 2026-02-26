# Goal

Ship a minimal `RewardEscrow` implementation that reuses Flow's existing `managerRewardPool` stream path so the top-level flow can escrow a reward slice and stakers can claim at goal end.

Success criteria:
- No new stream routing path is introduced; reward funding uses existing `managerRewardPool` behavior.
- Staker claims are enabled at goal resolution.
- Failure/expiry behavior is explicit and tested.

# Scope

In scope (v1):
- Add `RewardEscrow` contract for SuperToken rewards.
- Add `IRewardEscrow` interface.
- Wire `GoalTreasury` to finalize escrow at goal finalization.
- Configure top-level flow to point `managerRewardPool` at `RewardEscrow`.
- Claim formula: final-weight pro-rata (no stake-time in v1).
- Add/adjust tests in `test/goals/**` and any required flow integration coverage.

Out of scope (v1):
- Stake-time accounting (`integral stake dt`).
- Per-budget success-conditioned reward points.
- Transferable claim tokens.
- Multi-level cascading reward splits across child flows.

# Constraints

- Do not modify `lib/**`.
- Keep reward routing on canonical Flow interfaces (`managerRewardPool`, `managerRewardPoolFlowRatePercent`).
- Preserve current goal lifecycle safety (flow stops on finalize, vault resolve still happens).
- Keep implementation small and auditable; avoid introducing a second parallel treasury split path.

# Acceptance Criteria

- `RewardEscrow` receives SuperToken funds from Flow manager-reward stream.
- On goal finalize, escrow is finalized exactly once with terminal goal state.
- On `Succeeded`:
  - stakers can claim one time,
  - claim amount is proportional to final stake weight.
- On `Failed` or `Expired`:
  - staker claims are zero/non-redeemable,
  - escrowed funds follow defined fallback destination policy.
- Existing goal + flow behavior remains intact outside reward path changes.
- Verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

# Proposed Design (v1)

1. Funding path
- Keep current Flow split math.
- Set top-level flow `managerRewardPool = RewardEscrow`.
- Set top-level `managerRewardPoolFlowRatePercent = rewardRateBps` (example `200_000` for 20%).

2. Escrow state
- Immutable:
  - `superToken`
  - `goalTreasury`
  - `stakeVault`
- Finalization snapshot:
  - `finalized`
  - `finalState` (succeeded/failed/expired)
  - `rewardPoolSnapshot` (escrow token balance at finalize)
  - `totalWeightSnapshot` (`stakeVault.totalWeight()` at finalize)
- Claims:
  - `claimed[address]`
  - `totalClaimed` (accounting + diagnostics)

3. Finalization flow
- `GoalTreasury._finalize(...)` order:
  1) set flow rate to zero,
  2) finalize reward escrow (snapshot),
  3) mark stake vault resolved,
  4) emit final events.

4. Claim logic
- `claim(to)`:
  - requires finalized and not already claimed.
  - if final state is not `Succeeded`, marks claimed and returns `0`.
  - if succeeded:
    - read `userWeight = stakeVault.weightOf(msg.sender)`,
    - compute `amount = rewardPoolSnapshot * userWeight / totalWeightSnapshot`,
    - transfer SuperToken to `to`.

5. Failure/expiry funds policy (v1)
- On `Failed`/`Expired`, claims return `0`.
- Goal treasury can sweep escrowed balance post-finalize via explicit `sweepFailed(to)` call.

6. Known v1 simplification
- Reward share uses final weight, not stake-time.
- Operational note: claim should be done before stake withdrawal for expected UX (unless we add stricter vault-level gating in a follow-up).

# Files Expected To Change

- `src/interfaces/IGoalTreasury.sol`
- `src/goals/GoalTreasury.sol`
- `src/interfaces/IRewardEscrow.sol` (new)
- `src/goals/RewardEscrow.sol` (new)
- `test/goals/GoalTreasury.t.sol`
- `test/goals/GoalRevnetIntegration.t.sol` (or a new focused reward-escrow integration suite)
- Possibly small updates to shared test helpers for deployment wiring.

# Progress Log

- 2026-02-18: Drafted v1 plan for review with minimal scope and explicit non-goals.
- 2026-02-18: Confirmed existing Flow already supports reward stream split and pool migration via manager-reward path.
- 2026-02-18: Implemented `RewardEscrow` + `IRewardEscrow`, wired `GoalTreasury` finalize hook, and added coverage in `test/goals/RewardEscrow.t.sol` and `test/goals/GoalTreasury.t.sol`.
- 2026-02-18: Verification passed with `forge build -q` and `pnpm -s test:lite`.
- 2026-02-18: Expanded test depth with additional RewardEscrow edge/fuzz tests, finalize-order assertions in GoalTreasury tests, and a new stateful invariant suite (`test/invariant/RewardEscrow.invariant.t.sol`).

# Open Risks

- V1 reward formula differs from docs' stake-time model (intentional simplification).
- Without extra gating, users who withdraw stake before claiming may get lower/no claims than expected.
- `setManagerRewardPool` is mutable by owner/manager; governance/ops policy should define whether this is allowed post-launch.
- Child flows currently inherit parent reward percent defaults; top-level-only reward policy should be enforced in deployment/config.

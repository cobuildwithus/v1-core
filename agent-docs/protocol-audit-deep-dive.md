# Protocol Deep Dive for Logic Audit

Last verified: 2026-02-24

## Why this document exists

This auditor-focused walkthrough explains how the protocol changes state and moves funds.
Use it during code review to quickly answer:

- what can change state,
- what can move funds,
- when assets unlock,
- and which paths are intentionally impossible.

## System map (high level)

The protocol has three coupled subsystems:

1. Flow system (`src/Flow.sol`, `src/flows/CustomFlow.sol`)
- Holds/streams SuperToken balances.
- Maintains recipient allocations; child allocation sync is pipeline-driven and best-effort.
- Enforces flow-rate safety caps and bounded child updates.

2. Goal/Budget treasury + staking/rewards (`src/goals/**`, `src/hooks/GoalRevnetSplitHook.sol`)
- Drives goal and budget lifecycle states.
- Accepts funding (hook + donations), sets flow rates, and finalizes residual balances.
- Locks stake, computes reward points, and pays out through escrow.

3. TCR/arbitration curation (`src/tcr/**`)
- Curates budgets via request/challenge/dispute lifecycle.
- Activates or removes budgets based on TCR outcomes.
- Handles fee/reward escrow for request rounds and arbitrator rounds.

## Core contracts and what they own

### Flow domain

- `Flow.sol`: canonical stream engine and custody point for treasury-linked SuperToken balances.
- `CustomFlow.sol`: concrete flow entrypoint using the Flow core.
- `FlowRates.sol`: max-safe rate math and flow-rate buffer calculations.
- `GoalFlowAllocationLedgerPipeline.sol`: optional post-commit checkpointing/validation for goal allocation modes.

### Goal/Budget domain

- `GoalTreasury.sol`: goal state machine and final settlement policy.
- `BudgetTreasury.sol`: budget state machine, pass-through flow policy, parent residual returns.
- `TreasuryBase.sol`: shared donation ingress, balance reads, and helper mechanics.
- `GoalStakeVault.sol`: stake custody, rent accrual/withholding, juror lock/exit/slashing.
- `BudgetStakeLedger.sol`: accounting-only points ledger for budget success weighting.
- `RewardEscrow.sol`: final reward pools, snapshot finalization, claim and failed-path sweep behavior.
- `GoalRevnetSplitHook.sol`: funding ingress and success-state settlement split from revnet flow.
- `UMATreasurySuccessResolver.sol`: assertion registration/dispute/result callbacks and finalization relay.

### TCR/arbitration domain

- `GeneralizedTCR.sol`: item request/challenge lifecycle and round fee accounting.
- `ERC20VotesArbitrator.sol`: dispute rounds, rulings, voter rewards, optional stake-vault juror slashing mode.
- `BudgetTCR.sol`: maps TCR outcomes to budget stack deployment/activation/removal terminalization.
- `BudgetTCRDeployer.sol`: deploy helper used by `BudgetTCR`.
- `BudgetTCRValidator.sol`: listing constraints (deadlines/durations/oracle requirements).

## State machines

### Goal lifecycle (`GoalTreasury`)

State enum: `Funding -> Active -> (Succeeded | Expired | Failed)`.

Current practical transitions:

- `Funding -> Active`
  - Trigger: `sync()`.
  - Guard: pre-deadline, min-raise satisfied using `superToken.balanceOf(flow)`.

- `Funding -> Expired`
  - Trigger: `sync()`.
  - Guard: funding/deadline window elapsed without qualifying activation.

- `Active -> Succeeded`
  - Trigger: `resolveSuccess()` or `sync()`.
  - Guard: pending assertion exists and verifies truthful.

- `Active -> Expired`
  - Trigger: `sync()`.
  - Guard: deadline reached with no truthful resolved assertion.

- `Failed` exists in the enum, but no exposed manual failure path currently reaches `_finalize(Failed)`.

Important notes:

- Success assertion registration is resolver-only and must occur pre-deadline.
- If assertion was registered in time, success may still finalize after deadline once UMA resolves.
- `sync()` is permissionless and the canonical progression path.

### Budget lifecycle (`BudgetTreasury`)

State enum: `Funding -> Active -> (Succeeded | Failed | Expired)`.

Transitions:

- `Funding -> Active`
  - Trigger: `sync()`.
  - Guard: before/at funding deadline and activation threshold reached.

- `Funding -> Expired`
  - Trigger: `sync()`.
  - Guard: funding deadline passed before activation threshold.

- `Active -> Succeeded`
  - Trigger: `resolveSuccess()` (resolver-only).
  - Guard: truthful pending assertion and success-resolution not disabled.

- `Funding/Active -> Failed`
  - Trigger: `resolveFailure()`.
  - Guard: controller-only, time-gated; for active budgets requires deadline reached and no pending success assertion.

- `Active -> Expired`
  - Trigger: `sync()`.
  - Guard: deadline reached with no pending success assertion.

Budget removal interaction:

- Accepted budget removal in `BudgetTCR` first marks the budget pending finalization.
- `finalizeRemovedBudget()` then removes the recipient, calls `disableSuccessResolution()`, and attempts terminal resolution.
- After disable succeeds, later budget success resolution is permanently blocked.

### TCR item/request lifecycle (`GeneralizedTCR`)

Item status: `Absent`, `Registered`, `RegistrationRequested`, `ClearingRequested`.

Request phase: request submission -> challenge window -> (unchallenged execution or dispute path) -> resolved.

Typical paths:

- Add item: `Absent -> RegistrationRequested -> Registered`.
- Remove item: `Registered -> ClearingRequested -> Absent`.
- Challenge path creates dispute in arbitrator and final status follows ruling.

### Arbitrator lifecycle (`ERC20VotesArbitrator`)

Internal dispute progression:

- `Pending -> Active -> Reveal -> Solved` (timestamp/window-gated).
- `executeRuling()` then calls back the arbitrable (TCR) to finalize request outcome.

Stake-vault mode supports permissionless juror slashing transfers to reward escrow when conditions are met.

### Assertion lifecycle (`UMATreasurySuccessResolver`)

For each treasury assertion:

1. Resolver registers pending assertion ID/time on treasury.
2. UMA dispute callback marks disputed state.
3. UMA resolution callback records truth result.
4. Resolver `finalize()` relays to treasury:
- truthful -> treasury `resolveSuccess()`.
- false/disallowed -> treasury `clearSuccessAssertion()`.

## End-to-end fund flow

### 1) Funding ingress

Path A: Revnet hook funding

- `GoalRevnetSplitHook.processSplitWith` checks allowed caller/token/project/group and treasury state.
- If treasury can accept funding, hook forwards value into goal `Flow` and records hook funding in treasury telemetry.

Path B: Direct donations

- `donateSuperToken(amount)`: transfer SuperToken directly to flow.
- `donateUnderlyingAndUpgrade(amount)`: pull underlying, upgrade, forward to flow.
- Goal treasury increments `totalRaised`; budget treasury uses balance-based accounting only.

### 2) Active distribution

Goal treasury flow-rate policy:

- Spend-down target over remaining time.
- Sync fallback order: target rate -> max-safe capped rate -> zero.

Budget treasury flow-rate policy:

- Pass-through target based on measured incoming net flow + outgoing flow.
- Capped by flow safety limits.

Flow system behavior:

- `Flow` streams through Superfluid pools and updates recipient/member units from committed allocations.
- Child allocation sync side effects run through `GoalFlowAllocationLedgerPipeline` and are best-effort with emitted outcomes.

### 3) Terminal settlement

Goal treasury finalization (`_finalize`):

1. Clear pending assertion state.
2. Set terminal state.
3. Zero flow rate.
4. Sweep all remaining SuperToken from flow to treasury.
5. Settle residual policy:
- `Succeeded`: split treasury-held residual between reward escrow and burn.
- `Expired/Failed`: burn 100%.
6. Finalize reward escrow and mark stake vault resolved timestamp.

Budget treasury finalization (`_finalize`):

1. Set terminal state and resolved timestamp.
2. Zero child outflow.
3. Sweep residual from budget child flow back to parent goal flow.
4. Mark stake vault resolved timestamp.

Late residual handling:

- Goal: `settleLateResidual()` reapplies terminal residual policy for post-finalization inflows.
- Budget: `settleLateResidualToParent()` re-sweeps late residual back to parent flow.

### 4) Reward escrow payout path

On goal success finalization:

- Escrow finalizes snapshots and stake-ledger final state.
- Claimants call `claim(to)` for a one-time snapshot pro-rata component plus an incremental rent-indexed component (when applicable).

On non-success terminal states:

- `releaseFailedAssetsToTreasury()` moves escrow-held assets back for terminal no-reward handling.
- Treasury `sweepFailedAndBurn()` applies burn policy for swept assets.

Succeeded-state edge case:

- `releaseFailedAssetsToTreasury()` is also allowed when goal state is `Succeeded` but the snapshot has zero successful budget points.

### 5) Stake lock/unlock and rent

`GoalStakeVault` custody/locking:

- Users deposit goal/cobuild stake.
- Withdrawals require goal resolved and available unlocked amount.
- Rent debt is computed and withheld on withdrawal, then routed to configured recipient.

Juror locks:

- Juror opt-in locks stake for arbitrator mode.
- Exit requires `requestJurorExit()` then `finalizeJurorExit()` after cooldown (`max(requestedAt, goalResolvedAt) + 7 days`).
- Arbitrator slashing can transfer stake directly to reward escrow.

## Unlock matrix (what must be true)

| Action | Required conditions |
| --- | --- |
| Hook funding accepted | Goal not terminal; before deadline; not in post-min-raise-deadline-below-min terminalizing condition. |
| Goal activation | Flow balance `>= minRaise` under deadline constraints. |
| Goal success | Goal `Active`; pending assertion; assertion resolves truthful. |
| Budget activation | Budget `Funding`; `now <= fundingDeadline`; flow balance `>= activationThreshold`. |
| Budget success | Budget `Active`; success resolution not disabled; resolver calls with truthful pending assertion. |
| Budget manual failure | Controller-only; correct state/time gate; no pending success assertion for active failure path. |
| Stake withdrawal | Goal resolved; amount unlocked and not juror-locked; rent withheld on exit. |
| Juror final exit | Cooldown elapsed since request and resolution anchor. |
| Reward claim | Escrow finalized; success state; positive entitlement. |

## High-value audit targets and invariants

1. Treasury terminalization idempotency and irreversible state transitions.
2. Flow-rate sync liveness under revert/fallback scenarios.
3. Hook routing correctness by treasury state and minting window.
4. Goal success independence from unresolved budgets (by design) and timestamp anchoring effects.
5. Budget removal guarantees: recipient removed + success disabled + retryable terminalization.
6. Stake rent math and withdrawal accounting (including rounding/dust and repeated withdrawals).
7. Reward escrow claim math and claim cursor monotonicity.
8. Submission deposit strategy behavior in TCR (fail-closed surface).
9. Arbitration reward routing, invalid-round sink, and one-shot withdrawal semantics.
10. Child sync best-effort observability and permissionless repair path liveness.

## Practical audit sequence

1. Start with treasury state transitions and terminal settlement (`GoalTreasury`, `BudgetTreasury`).
2. Validate all ingress gates (`GoalRevnetSplitHook`, donations) against lifecycle assumptions.
3. Confirm rate-sync behavior from treasury -> flow -> child flows (including fallback and reverts).
4. Trace reward and stake accounting boundaries (`GoalStakeVault`, `BudgetStakeLedger`, `RewardEscrow`).
5. Audit TCR and arbitrator economic loops (contributions, dispute fees, refunds/rewards, sink routes).
6. Cross-check invariants via `test/invariant/**` and targeted unit tests for each module.

## Recommended code and test anchors

Core code anchors:

- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/GoalStakeVault.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/RewardEscrow.sol`
- `src/Flow.sol`
- `src/library/FlowRates.sol`
- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `src/tcr/BudgetTCR.sol`
- `src/goals/UMATreasurySuccessResolver.sol`

High-signal tests/invariants:

- `test/goals/GoalTreasury.t.sol`
- `test/goals/BudgetTreasury.t.sol`
- `test/goals/GoalRevnetSplitHook.t.sol`
- `test/goals/RewardEscrow.t.sol`
- `test/goals/GoalStakeVault.t.sol`
- `test/goals/BudgetStakeLedgerEconomics.t.sol`
- `test/BudgetTCR.t.sol`
- `test/GeneralizedTCR*.t.sol`
- `test/ERC20VotesArbitrator*.t.sol`
- `test/invariant/TreasuryTerminalLifecycle.invariant.t.sol`
- `test/invariant/RewardEscrow.invariant.t.sol`
- `test/invariant/TCRAndArbitrator.invariant.t.sol`
- `test/invariant/GoalHookRoutingSplit.invariant.t.sol`

## Known design-intent edge cases (easy to misread during audit)

- `GoalState.Failed` exists but is not currently reached by an exposed manual failure route.
- Goal success does not wait for all budgets to resolve; snapshot eligibility is anchored at goal success timestamp.
- Budget success can be permanently disabled on accepted removal.
- Direct flow balance can satisfy activation thresholds even without hook funding telemetry.
- Child-allocation sync failures in pipeline paths are emitted (skip/attempt outcome) while parent allocation maintenance continues.

## Companion docs to keep open while auditing

- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/module-boundary-map.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/references/tcr-and-arbitration-map.md`
- `agent-docs/RELIABILITY.md`
- `agent-docs/SECURITY.md`

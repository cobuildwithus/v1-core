# Protocol Deep Dive for Logic Audit

Last verified: 2026-03-03

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

2. Goal/Budget treasury + staking/underwriting (`src/goals/**`, `src/hooks/GoalRevnetSplitHook.sol`)
- Drives goal and budget lifecycle states.
- Accepts funding (hook + donations), sets flow rates, and finalizes residual balances.
- Locks stake, tracks budget coverage, accrues premium, and routes failure slashing via underwriter router.

3. TCR/arbitration curation (`src/tcr/**`)
- Curates budgets via request/challenge/dispute lifecycle.
- Activates or removes budgets based on TCR outcomes.
- Handles fee/reward accounting for request rounds and arbitrator rounds.

## Core contracts and what they own

### Flow domain

- `Flow.sol`: canonical stream engine and custody point for treasury-linked SuperToken balances.
- `CustomFlow.sol`: concrete flow entrypoint using the Flow core.
- `FlowRates.sol`: max-safe rate math and flow-rate buffer calculations.
- `GoalFlowAllocationLedgerPipeline.sol`: optional post-commit goal-ledger checkpointing mode; child sync is best-effort, premium checkpointing is fail-closed.

### Goal/Budget domain

- `GoalTreasury.sol`: goal state machine and final settlement policy.
- `BudgetTreasury.sol`: budget state machine, pass-through flow policy, parent residual returns.
- `TreasuryBase.sol`: shared donation ingress, balance reads, and helper mechanics.
- `StakeVault.sol`: stake custody, juror lock/exit/slashing, underwriter withdrawal preparation.
- `BudgetStakeLedger.sol`: coverage-only stake accounting per budget with checkpoints for vote snapshots.
- `PremiumEscrow.sol`: budget premium accrual/checkpointing and terminal slashing dispatch.
- `UnderwriterSlasherRouter.sol`: slashed-token conversion/upgrade/forwarding to goal funding path.
- `GoalRevnetSplitHook.sol`: funding ingress and terminal/success settlement routing from revnet flow.
- `UMATreasurySuccessResolver.sol`: assertion registration/dispute/result callbacks and finalization relay.

### TCR/arbitration domain

- `GeneralizedTCR.sol`: item request/challenge lifecycle and round fee accounting.
- `ERC20VotesArbitrator.sol`: dispute rounds, rulings, voter rewards, optional stake-vault juror slashing mode.
- `BudgetTCR.sol`: maps TCR outcomes to budget stack deployment/activation/removal terminalization.
- `BudgetTCRDeployer.sol`: deploy helper used by `BudgetTCR`.
- `BudgetTCRValidator.sol`: listing constraints (deadlines/durations/oracle requirements).

## State machines

### Goal lifecycle (`GoalTreasury`)

State enum: `Funding -> Active -> (Succeeded | Expired)`.

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

- Goal treasury has no `Failed` terminal state and no manual failure entrypoint.

Important notes:

- Success assertion registration is resolver-only and must occur pre-deadline (except explicit grace-policy handling).
- If assertion was registered in time, success may still finalize after deadline once UMA resolves.
- `sync()` is permissionless and the canonical progression path.

### Budget lifecycle (`BudgetTreasury`)

State enum: `Funding -> Active -> (Succeeded | Failed | Expired)`.

Transitions:

- `Funding -> Active`
  - Trigger: `sync()`.
  - Guard: activation threshold reached while still in `Funding` (including post-`fundingDeadline` sync calls).

- `Funding -> Expired`
  - Trigger: `sync()`.
  - Guard: funding window has ended and activation threshold is still unmet at sync time.

- `Active -> Succeeded`
  - Trigger: `resolveSuccess()` (resolver-only).
  - Guard: truthful pending assertion and success-resolution not disabled.

- `Funding/Active -> Failed`
  - Trigger: `resolveFailure()`.
  - Guard: controller-only, time-gated; for active budgets requires deadline reached and no pending success assertion.

- `Active -> Expired`
  - Trigger: `sync()`.
  - Guard: deadline reached with no pending success assertion (and post-deadline grace rules exhausted).

Budget removal interaction:

- Accepted budget removal in `BudgetTCR` first marks the budget pending finalization.
- `finalizeRemovedBudget()` removes the recipient and attempts terminal resolution with branch-specific handling:
  - pre-activation removals disable success resolution (`disableSuccessResolution()`), permanently blocking later budget success,
  - activation-locked removals preserve success-resolution eligibility while force-zeroing forward spend.

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

Stake-vault mode supports permissionless juror slashing:

- caller bounty routes to slash caller,
- remaining slash routes to winner pools (or `invalidRoundRewardsSink` on no-winner rounds).

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
- Treasury `processHookSplit` routes by state:
  - funding-open -> convert/forward to goal flow + telemetry,
  - succeeded+minting-open -> success settlement burn,
  - closed nonterminal -> deferred treasury custody,
  - terminal -> terminal settlement policy.

Path B: Direct donations

- `donateUnderlyingAndUpgrade(amount)`: pull underlying, upgrade, forward to flow.
- Goal treasury increments `totalRaised`; budget treasury uses balance-based accounting only.

### 2) Active distribution

Goal treasury flow-rate policy:

- Spend-down target over remaining time.
- Sync fallback order: target rate -> max-safe bounded rate -> zero.
- Goal-level coverage-rate clamping is removed; underwriting is enforced via budget credit-line recipient gating in `BudgetTCR.syncBudgetTreasuries`.

Budget treasury flow-rate policy:

- Pass-through target from trusted parent member flow-rate only.

Flow system behavior:

- `Flow` streams through Superfluid pools and updates recipient/member units from committed allocations.
- Child allocation sync runs through `GoalFlowAllocationLedgerPipeline` as best-effort with emitted outcomes.
- Premium-escrow checkpointing in the same pipeline is consensus-critical and fail-closed (allocation commits revert on checkpoint failure).

### 3) Terminal settlement

Goal treasury finalization (`_finalize`):

1. Clear pending assertion state and set terminal state.
2. Attempt flow stop (best-effort).
3. Sweep residual SuperToken from flow to treasury and settle by burning downgraded underlying.
4. Settle deferred hook funding by the same terminal settlement policy.
5. Attempt stake-vault resolution mark (`markGoalResolved`) best-effort.

Budget treasury finalization (`_finalize`):

1. Set terminal state and resolved timestamp.
2. Zero child outflow best-effort.
3. Close premium escrow with terminal metadata best-effort.
4. Sweep residual from budget child flow back to parent goal flow best-effort.

Late residual handling:

- Goal: `settleLateResidual()` reapplies terminal residual policy for post-finalization inflows.
- Budget: `settleLateResidualToParent()` re-sweeps late residual back to parent flow.

### 4) Premium accrual and slashing path

Runtime premium path:

- Budget child flow manager reward stream routes to per-budget `PremiumEscrow`.
- `PremiumEscrow` uses coverage checkpoints from `BudgetStakeLedger` to index premium entitlement.
- If total coverage is zero, premium is recycled to goal funding path.

Failure slashing path:

- On terminal failed/post-activation-expired budget, `PremiumEscrow.slash(underwriter)` computes exposure-weighted slash.
- `StakeVault.slashUnderwriterStake` transfers slashed goal/cobuild tokens to `UnderwriterSlasherRouter`.
- Router best-effort converts cobuild to goal token, upgrades to SuperToken, and forwards to goal funding target.
- Conversion/forward failures stay observable and are retryable.

### 5) Stake lock/unlock

`StakeVault` custody/locking:

- Users deposit goal/cobuild stake.
- Underwriter withdrawals after goal resolution require caller-scoped preparation over tracked budgets.

Juror locks:

- Juror opt-in locks stake for arbitrator mode.
- Exit requires `requestJurorExit()` then `finalizeJurorExit()` after cooldown (`max(requestedAt, goalResolvedAt) + 7 days`).
- Arbitrator slashing can transfer stake via configured slash routes.

## Unlock matrix (what must be true)

| Action | Required conditions |
| --- | --- |
| Hook funding accepted | Goal not terminal; before deadline; not in post-min-raise-deadline-below-min terminalizing condition. |
| Goal activation | Flow balance `>= minRaise` under deadline constraints. |
| Goal success | Goal `Active`; pending assertion; assertion resolves truthful. |
| Budget activation | Budget `Funding`; flow balance `>= activationThreshold` (including post-`fundingDeadline` sync if threshold is met before expiry finalization). |
| Budget success | Budget `Active`; success resolution not disabled; resolver calls with truthful pending assertion. |
| Budget manual failure | Controller-only; correct state/time gate; no pending success assertion for active failure path. |
| Underwriter stake withdrawal | Goal resolved and caller has completed required `prepareUnderwriterWithdrawal` work for current epoch. |
| Juror final exit | Cooldown elapsed since request and resolution anchor. |
| Premium claim | Escrow checkpointed coverage and positive indexed entitlement. |

## High-value audit targets and invariants

1. Treasury terminalization idempotency and irreversible state transitions.
2. Flow-rate sync liveness under revert/fallback scenarios.
3. Hook routing correctness by treasury state and minting window.
4. Premium-escrow checkpoint/accrual/slash invariants and idempotence.
5. Budget removal guarantees: recipient removed + retryable terminalization; success disablement is branch-specific (pre-activation only).
6. Underwriter withdrawal preparation accounting and caller isolation.
7. Arbitrator slash routing, invalid-round sink behavior, and one-shot withdrawal semantics.
8. Submission deposit strategy behavior in TCR (fail-closed surface).
9. Child sync best-effort observability/repair liveness plus fail-closed premium-checkpoint invariants.

## Practical audit sequence

1. Start with treasury state transitions and terminal settlement (`GoalTreasury`, `BudgetTreasury`).
2. Validate all ingress gates (`GoalRevnetSplitHook`, donations) against lifecycle assumptions.
3. Confirm rate-sync behavior from treasury -> flow -> child flows (including fallback and reverts).
4. Trace stake, premium, and slashing boundaries (`StakeVault`, `BudgetStakeLedger`, `PremiumEscrow`, `UnderwriterSlasherRouter`).
5. Audit TCR and arbitrator economic loops (contributions, dispute fees, refunds/rewards, sink routes).
6. Cross-check invariants via `test/invariant/**` and targeted unit tests for each module.

## Recommended code and test anchors

Core code anchors:

- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/StakeVault.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/UnderwriterSlasherRouter.sol`
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
- `test/goals/PremiumEscrow.t.sol`
- `test/goals/StakeVault.t.sol`
- `test/goals/BudgetStakeLedgerCoverageCutover.t.sol`
- `test/goals/UnderwriterSlasherRouter.t.sol`
- `test/goals/UnderwritingIntegration.t.sol`
- `test/BudgetTCR.t.sol`
- `test/GeneralizedTCR*.t.sol`
- `test/ERC20VotesArbitrator*.t.sol`
- `test/invariant/TreasuryTerminalLifecycle.invariant.t.sol`
- `test/invariant/TCRAndArbitrator.invariant.t.sol`
- `test/invariant/GoalHookRoutingSplit.invariant.t.sol`

## Known design-intent edge cases (easy to misread during audit)

See `agent-docs/references/known-design-intent-edge-cases.md`.

## Companion docs to keep open while auditing

- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/module-boundary-map.md`
- `agent-docs/references/known-design-intent-edge-cases.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/references/tcr-and-arbitration-map.md`
- `agent-docs/RELIABILITY.md`
- `agent-docs/SECURITY.md`

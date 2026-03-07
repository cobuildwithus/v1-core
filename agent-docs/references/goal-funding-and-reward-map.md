# Goal Funding and Underwriting Map

Hard-cutover note (2026-03-01): the legacy goal RewardEscrow/points subsystem is removed from runtime code. This map describes the current premium-escrow + underwriter slashing model.

## Goal Funding Path

1. Revnet reserved-token splits enter through `GoalRevnetSplitHook.processSplitWith`.
2. Hook validates caller/context and forwards value handling to `GoalTreasury.processHookSplit`.
3. If `goalTreasury.canAcceptHookFunding()`, treasury converts/forwards into goal `Flow` SuperToken balance and records accepted funding telemetry (`HookFundingRecorded`, `totalRaised`).
4. Treasury also accepts direct donations while funding is open:
   - `donateUnderlyingAndUpgrade(amount)` pulls underlying, upgrades, and forwards into the goal flow.
   - donation receipts are counted in `totalRaised` (telemetry).
5. Goal min-raise lifecycle checks use live treasury balance (`superToken.balanceOf(flow)`), so direct flow inflows can satisfy activation.
6. If treasury state is `Succeeded` and minting remains open, hook splits are success-settled by burning source value (no reward-escrow split branch).
7. If funding is closed but treasury is still nonterminal, hook value is converted to SuperToken and accumulated as deferred funding on treasury.
8. If treasury is terminal, hook value is converted and settled through terminal residual policy.

## Goal Lifecycle Path

1. Treasury begins in `Funding`.
2. `sync()` handles both funding activation and active-state flow-rate updates using spend-pattern targeting (linear today) from treasury balance and remaining time:
   - linear target is proactively guarded by buffer-aware liquidation-horizon constraints when currently affordable,
   - write fallback ladder remains best-effort (target -> bounded fallback -> zero).
3. Success is assertion-backed and resolver-gated:
   - immutable `successResolver` controls assertion registration/clearing,
   - goal `resolveSuccess` is success-resolver-only and requires a pending truthful assertion,
   - post-deadline false/invalid outcomes settle fail-closed to `Expired` semantics (with reassert-grace policy).
4. Finalization is state-first: terminal state/timestamp commit before external side effects.
5. Goal terminal side effects are best-effort and permissionlessly retryable via `retryTerminalSideEffects`:
   - flow stop,
   - residual settlement,
   - deferred-hook settlement,
   - stake-vault `markGoalResolved`.
6. Goal residual settlement always burns downgraded underlying through controller policy:
   - `Succeeded`: success-residual burn memo path,
   - `Expired`: terminal-residual burn memo path.
7. `sync()` remains terminal no-op; late inflows can be handled via `settleLateResidual()`.

## Budget Lifecycle + Premium Escrow Path

1. Parent funding enters each budget child flow from the goal flow recipient path.
2. Budgets are deployed as child flows where the budget treasury is child `flowOperator`/`sweeper`, and manager reward stream is routed to per-budget `PremiumEscrow` at `budgetPremiumPpm`.
3. Budget treasury active target flow-rate is trusted incoming plus balance spenddown:
   - trusted incoming component: `max(parent.getMemberFlowRate(child), 0)`,
   - spenddown component: `treasuryBalance / timeRemaining`,
   - total target is the saturated sum of both components (`int96.max` cap).
4. Budget treasury is assertion-backed for success and controller-gated for manual failure (`resolveFailure`) under deadline constraints.
5. Budget finalization is state-first, then best-effort side effects:
   - child outflow stop,
   - premium escrow close with terminal metadata,
   - residual sweep back to parent goal flow.
6. `BudgetTCR.syncBudgetTreasuries(itemIDs)` provides permissionless best-effort treasury sync batching for liveness.
7. Budget delisting semantics (on-chain remove/finalize-removed path) are split:
   - pre-activation delist is fail-closed and terminalizes,
   - activation-locked delist detaches parent funding and forces spend-stop, but is not itself guaranteed permanent shutdown until treasury terminalization.

## Stake + Underwriting Path

- `StakeVault` tracks goal + cobuild stake, supports juror locks/exits, and exposes live allocator weight.
- Goal-token deposit weighting in `StakeVault` is composed of:
  - issuance base from snapshotted init ruleset weight (`goalAmount * weightScale / snappedWeight`),
  - plus a snapshotted reserved-percent premium that decays linearly from full at activation/pre-activation to zero at deadline.
- `StakeVault` snapshots both goal ruleset weight and reserved percent once at initialization; later ruleset drift does not reprice existing or future deposits for that vault instance.
- `reservedPercent == 10_000` at snapshot is invalid and vault initialization reverts.
- Cobuild deposits remain 1:1 amount-to-weight.
- Deposits still require live staking-open state (`currentOf(goalRevnetId).weight > 0`) when each deposit executes.
- `BudgetStakeLedger` is coverage-only accounting (per-user and per-budget allocated stake plus checkpoint history for vote snapshots).
- `PremiumEscrow` checkpoints per-underwriter budget coverage and accrues premium from indexed inflows.
- Premium claims are gated on goal success (`GoalTreasury.state() == Succeeded`).
- Premium inflow with zero budget coverage is recycled to goal funding path (no orphan premium custody).
- On goal `Expired`, escrowed premium can be swept via `PremiumEscrow.burnOnGoalFailure()` to goal flow for terminal residual burn settlement.
- On escrow close to `Failed` or post-activation `Expired`, `PremiumEscrow.slash(underwriter)` treats `creditDrawn` as first-loss principal attributed to that underwriter, caps by strict slash-percent principal (`peakCov * budgetSlashPpm / 1e6`), and calls `UnderwriterSlasherRouter`.
- Slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on budget
  `executionDuration`.
- `UnderwriterSlasherRouter` receives slashed stake via `StakeVault`, best-effort converts cobuild -> goal token, upgrades to goal SuperToken, and forwards to goal funding target; failures remain observable and retryable via `retryForwarding`.
- Post-goal-resolution underwriter withdrawals are caller-prepared, not globally budget-gated:
  - each underwriter runs `StakeVault.prepareUnderwriterWithdrawal(maxBudgets)` over registered budgets,
  - unresolved caller exposure blocks only that caller's withdrawals.

## Key Files

- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/StakeVault.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/UnderwriterSlasherRouter.sol`
- `src/allocation-strategies/BudgetFlowRouterStrategy.sol`

# Goal Funding and Underwriting Map

Hard-cutover note (2026-03-01): the legacy goal RewardEscrow/points subsystem is removed from runtime code. This map describes the current premium-escrow + underwriter slashing model.

## Community root routing path

1. A payer can route an evergreen community revnet payment through `CobuildCommunityTerminal`.
   - `CobuildCommunityTerminalFactory.deployFor(...)` deterministically deploys the community-scoped `CobuildSplitHook`, initializes it with the shared `CobuildCommunityTerminal` as fixed `routeSetter`, and registers the community on that terminal in the same transaction via an owner-signed payload.
   - Manual registration remains available through `CobuildCommunityTerminal.registerCommunity(...)`, but the community must already point both its native ETH terminal and registered payment-token terminal at the shared terminal.
2. The shared canonical terminal seeds a one-shot pending route on `CobuildSplitHook` before calling the registered community funding path:
   - explicit metadata seeds an explicit per-payment route,
   - empty metadata means no explicit route, so the terminal will flush any newly created reserved tokens into backlog.
   - the terminal snapshots any preexisting controller backlog so only the current pay's newly created reserved-token
     delta can use the selected route when an explicit route exists.
   - native ETH either records directly on the community through the shared terminal (`directNativeAllowed`) or first
     buys the registered payment token from `paymentSourceRevnetId`; if that upstream native path is the same shared
     terminal, the conversion stays internal and self-source-safe; direct payment-token pays skip the conversion step.
   - canonical community pays go through the JB terminal store, so ruleset pause/weight/base-currency logic and pay
     hooks still run before reserved-token routing continues.
3. `CommunityGoalRegistry` is the canonical onchain source of donor-visible goals:
   - community listings use `GeneralizedTCR` request/challenge/arbitration flow with canonical `bytes32(goalId)` item ids,
   - the registry is ownerless and does not expose privileged system goals or pause controls,
   - each listed goal carries metadata only; selectability is derived from canonical deployment, funding context, terminal presence, and live `GoalTreasury.canAcceptHookFunding()` status.
   - terminal goals can be permissionlessly pruned from the donor-visible listed set via `pruneTerminalGoal(goalId)`.
4. `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury` for community routing.
5. Direct goal funding uses the shared `CobuildGoalTerminal`.
   - it resolves each goal's payment token and payment-source revnet from the registered goal treasury + stake vault at pay time,
   - native ETH funding converts through the resolved source revnet before forwarding to the goal's primary payment-token terminal.
6. If the terminal-created community pay minted reserved tokens, the terminal immediately calls the community controller's
   `sendReservedTokensToSplitsOf(...)` in the same transaction.
7. That controller callback invokes `CobuildSplitHook.processSplitWith(...)`.
8. If the callback carried a terminal-seeded pending route, the full current pay delta is forwarded into the selected
   child goals by paying each goal's primary terminal for the community token.
9. If the callback had no pending route, the full callback amount is deferred into hook-managed backlog.
10. All explicit routed payments record per-goal routing score; that score decays lazily with a 30-day half-life, and backlog flushes do not reinforce it.
11. Historical backlog retry is paginated through `flushHistoricalBacklog(maxGoalCount)`, so callers can flush the parked
   backlog in bounded chunks.
12. Historical backlog routing is derived only from selectable goals with non-zero decayed explicit-route score and always pays
   goal-treasury beneficiaries.
13. If the terminal-created pay minted no reserved tokens, the terminal clears the unused pending route instead of leaving
   stale routing state behind.
14. If older backlog was included in that controller flush, `CobuildSplitHook` parks that snapshotted backlog for later
   permissionless retry instead of routing it through the current payer's selection.
15. If no usable historical route exists, the split hook keeps that backlog on-hook for later
   permissionless historical flush instead of blocking canonical-terminal-routed mints.

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
2. `sync()` handles both funding activation and active-state flow-rate updates through configured `ISpendPolicy` targeting/sync-mode selection.
   - The current uncapped goal default is `LinearSpendPolicy(includeIncomingRate=false, maxTargetFlowRate=0, syncMode=LinearSpendDownFallback)`, so raw target remains treasury balance over remaining time with buffer-aware liquidation-horizon guarding and best-effort fallback writes when that sync mode is selected.
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
3. Budget treasury active target flow-rate is policy-only:
   - the repo-wide default budget deployment is `LinearSpendPolicy(includeIncomingRate=true, maxTargetFlowRate=0, syncMode=Capped)`,
   - that preserves trusted incoming plus balance spenddown:
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
- `PremiumEscrow` goal-flow receipt baseline/checkpoint reads fail closed on read failure; receipt accounting no longer falls back to zero or silently skips failed reads.
- Premium claims are gated on goal success (`GoalTreasury.state() == Succeeded`).
- Premium inflow with zero budget coverage is recycled to goal funding path (no orphan premium custody).
- On goal `Expired`, escrowed premium can be swept via `PremiumEscrow.burnOnGoalFailure()` to goal flow for terminal residual burn settlement.
- On escrow close to `Failed` or post-activation `Expired`, `PremiumEscrow.slash(underwriter)` treats `creditDrawn` as first-loss principal attributed to that underwriter, caps by strict slash-percent principal (`peakCov * budgetSlashPpm / 1e6`), and calls `UnderwriterSlasherRouter`.
- Slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on budget
  `executionDuration`.
- `BudgetTCRFactory` only preserves manual registry deposits when the submission-deposit strategy cleanly reports `supportsEscrowBonding() == false`; probe failures now fail deployment instead of silently downgrading escrow-bond policy.
- `UnderwriterSlasherRouter` receives slashed stake via `StakeVault`, best-effort converts cobuild -> goal token, upgrades to goal SuperToken, and forwards to goal funding target; failures remain observable and retryable via `retryForwarding`.
- Post-goal-resolution underwriter withdrawals are caller-prepared, not globally budget-gated:
  - each underwriter runs `StakeVault.prepareUnderwriterWithdrawal(maxBudgets)` over registered budgets,
  - unresolved caller exposure blocks only that caller's withdrawals.

## Key Files

- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/policies/*.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/StakeVault.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/UnderwriterSlasherRouter.sol`
- `src/allocation-strategies/BudgetFlowRouterStrategy.sol`
- `src/juicebox/CobuildCommunityTerminal.sol`
- `src/juicebox/CobuildCommunityTerminalFactory.sol`

# Goal Funding and Reward Map

## Goal Funding Path

1. Revnet reserved-token splits enter through `GoalRevnetSplitHook.processSplitWith`.
2. Hook validates context/caller and forwards split funds to treasury for policy/action routing.
3. If `goalTreasury.canAcceptHookFunding()`, treasury upgrades/forwards to flow super token and records accepted funding.
4. Treasury also accepts direct donations while funding is open:
   - `donateUnderlyingAndUpgrade(amount)` pulls underlying, upgrades, and forwards into the goal flow.
   - Donation receipts are counted in `totalRaised` (telemetry).
5. Goal min-raise lifecycle checks (`activate`, funding `sync`, funding expiry checks) use live treasury balance, so direct flow inflows can satisfy min-raise.
6. If treasury state is `Succeeded` and minting remains open, each split amount is partitioned by immutable treasury config `successSettlementRewardEscrowPpm`:
   - reward portion transfers directly to treasury-configured reward escrow,
   - complement is burned with no remainder sink.
7. If funding is closed but treasury is still nonterminal, split amounts are deferred on treasury (no irreversible burn) until terminal state is known.
8. If treasury is terminal and success-settlement mode is closed, split amounts use treasury terminal settlement policy (same reward/burn policy as terminal residual settlement).

## Goal Lifecycle Path

1. Treasury begins in funding state.
2. `sync()` handles both funding activation and active-state flow-rate updates using a spend-pattern target (linear for now) from treasury balance and remaining time (goal spend-down invariant), with proactive linear guardrails and write fallbacks:
   - for linear spend-down, proactively cap target by a buffer-derived liquidation-horizon bound when the target is currently buffer-affordable,
   - try the guarded target rate directly,
   - on write revert, retry with bounded fallback,
   - on continued write revert, retry at zero to avoid bricking transitions.
3. Success state transition no longer blocks on unresolved RewardEscrow-tracked budgets.
4. Success is assertion-backed with resolver-only direct treasury finalization:
   - immutable `successResolver` registers assertions via `registerSuccessAssertion(assertionId)`,
   - goal `resolveSuccess` is success-resolver-only and requires a pending truthful assertion id,
   - budget `resolveSuccess` is success-resolver-only and requires a pending truthful assertion id,
   - permissionless finalization remains available through resolver-level `finalize`/`settleAndFinalize`,
   - both can finalize after deadline when assertion registration conditions are satisfied (including the budget one-time post-deadline grace reassert path under Policy C).
   - while a success assertion is pending, active-state terminalization is blocked only until assertion resolution is known.
5. Finalization is state-first: terminal state/timestamp commit first, then external side effects are attempted best-effort.
6. Goal flow residual SuperToken balance is settled:
   - `Succeeded`: split by treasury-configured `successSettlementRewardEscrowPpm` into reward escrow + controller burn.
   - `Failed`/`Expired`: burn all via controller.
7. Permissionless `sync()` is the canonical non-success transition path:
   - `Funding` -> `Active` when min-raise is met before deadline; otherwise `Funding` -> `Expired` once funding/deadline windows elapse.
   - `Active` at/after `deadline` resolves deterministically for goals (`Succeeded` when pending assertion is settled truthful, `Expired` when no pending assertion or when pending assertion settles false/invalid, otherwise remains `Active` with zero target flow until assertion settlement).
   - `Budget` active at/after `deadline` opens a one-time post-deadline reassert grace when the first pending assertion settles false/invalid; if grace elapses with no new pending assertion (or the grace reassert settles false/invalid), it transitions to `Expired`.
   - Goal treasury exposes no manual failure entrypoint.
8. Post-finalization late inflows can be processed with `settleLateResidual`, which reapplies the same final-state residual policy.
9. Finalization side effects:
   - flow stop, residual settlement, reward-escrow finalize, and stake-vault marking are best-effort and permissionlessly retryable via `retryTerminalSideEffects`.
   - stake-vault unlock remains permissionlessly recoverable through `markGoalResolved()` once treasury is resolved.
  - for success with escrow configured:
    - reward escrow finalize may defer while tracked budgets remain unresolved, then complete via permissionless `retryTerminalSideEffects`,
    - points accrual snapshots use `successAt` as the goal-level cutoff timestamp,
    - budget success eligibility is evaluated from final resolved budget state (not `resolvedAt <= successAt`).
   - no manual hook transition is required; treasury state gates hook behavior directly.
10. Failed escrow reward sweeps (`sweepFailedAndBurn`) apply terminal treatment for both assets:
   - goal token sweep amount burns via controller,
   - cobuild sweep amount also burns via controller via `cobuildRevnetId` (defaults to `goalRevnetId`).

## Budget Lifecycle Path

1. Parent funding enters child flow from the goal flow recipient path.
2. Budgets are deployed as nested child flows but marked manager-synced, so the budget treasury (as child `flowOperator` and `recipientAdmin`) owns child flow-rate mutation while parent auto-sync skips that child.
3. Budget treasury accepts direct donations while funding is open:
   - `donateUnderlyingAndUpgrade(amount)`.
4. Active target flow-rate is trusted parent member flow-rate (`parent.getMemberFlowRate(child)`) only (budget pass-through invariant).
5. Activation threshold starts execution window with computed deadline.
6. Finalize path is state-first and then best-effort for child outflow stop + residual parent sweep.
7. Budget manual failure is controller-gated and deadline-gated:
   - `Funding` -> `Failed` only after `fundingDeadline`,
   - `Active` -> `Failed` only at/after `deadline`.
8. Budget success is assertion-backed and resolver-gated:
   - immutable `successResolver` registers/clears assertions and calls `resolveSuccess`,
   - success assertions are registration-gated to `Active` + `>= fundingDeadline` + `< deadline` by default, with a one-time post-deadline registration exception during active reassert grace,
   - success can finalize after deadline if assertion was initiated pre-deadline, or via the one-time post-deadline grace reassert (Policy C),
   - pending assertions block competing active-state terminalization races.
9. Accepted budget removals are activation-locked:
   - pre-activation removals disable success resolution (`disableSuccessResolution`) and make the budget success-ineligible,
   - post-activation removals stop forward spend/funding but preserve reward-history eligibility; those budgets remain
     success-eligible only if they later resolve terminal `Succeeded`.
10. Budget stake scoring cutoff is exogenous:
   - raw matured stake-time accrual runs until
     `min(goal success timestamp, budget fundingDeadline, budget activation timestamp, budget removal timestamp)`,
   - budget activation timestamp (`activatedAt`) is recorded when `sync()` executes the `Funding -> Active` transition (keeper-timing dependent),
   - payout points are window-normalized (`raw matured stake-time / scoring-window seconds`) using scoring window start anchored at budget registration time,
   - budget `resolvedAt` no longer truncates scoring.
11. Post-finalization late inflows can be processed with `settleLateResidualToParent`, reusing parent-sweep behavior.
12. Terminal side effects are permissionlessly retryable via `retryTerminalSideEffects`; `sync()` remains terminal no-op.
13. `BudgetTCR` exposes permissionless best-effort batch treasury sync (`syncBudgetTreasuries(itemIDs)`) to improve operational liveness:
   - skips undeployed/inactive item IDs,
   - continues across per-budget `sync()` failures.

## Stake and Reward Path

- Stake vault tracks goal-token + cobuild-token stake weight.
- Stake vault can charge always-on rent on both stake assets (accrued lazily, collected from withdraw principal, and forwarded to reward escrow).
- Stake vault can lock goal/cobuild stake for juror duty with delayed exit and snapshot-able juror voting weight.
- Arbitrator-driven juror slashing transfers slashed goal/cobuild stake to reward escrow.
- Slash settlement is taken from live staked balances (with juror-lock accounting clamped afterward), preventing exit-finalization slash evasion.
- `GoalStakeVault` projects live vault weight into goal-flow allocation permissions via built-in strategy methods.
- `BudgetFlowRouterStrategy` projects per-budget stake from `BudgetStakeLedger.userAllocatedStakeOnBudget(...)` into budget-flow allocation permissions via registered `childFlow -> recipientId` routing.
- Reward points use `BudgetStakeLedger` checkpointed effective stake (quantized to Flow unit-weight scale, `1e15`) with maturation/warmup: recent stake increments start unmatured and decay to full point-rate over a scoring-window-derived period (`window / 10`, clamped to `[1 second, 30 days]`).
- Reward points are fundraising-window scoped per budget and window-normalized: raw matured stake-time accrual stops at the earliest applicable exogenous cutoff (`activatedAt`, `fundingDeadline`, goal success, or removal), then divides by scoring-window seconds.
- Warmup and normalization are points-only on effective stake; sub-unit raw stake dust that does not affect Flow units does not accrue points.
- Budget stake-ledger checkpointing requires sorted/unique recipient-id arrays and reverts on malformed ordering.
- Reward escrow resolves budget identity from goal-flow recipient shape:
  - direct budget-treasury recipient, or
  - child-flow recipient whose `recipientAdmin` is the budget treasury.
- If configured with a goal SuperToken stream, reward escrow permissionlessly unwraps SuperToken -> goal token and finalization snapshots the normalized goal-token pool.
- Claims are success-gated at the goal level and pay pro-rata against successful-budget normalized matured-support points, plus indexed rent inflows distributed by the same points.

## Key Files

- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/GoalStakeVault.sol`
- `src/goals/RewardEscrow.sol`
- `src/allocation-strategies/BudgetFlowRouterStrategy.sol`

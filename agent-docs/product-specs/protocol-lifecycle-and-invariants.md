# Protocol Lifecycle and Invariants

## Scope

This spec captures stable lifecycle and behavior contracts across Flow, goals/treasury, and TCR/arbitrator modules.

## Lifecycle Contracts

### Flow lifecycle

- Flows initialize via `CustomFlow.initialize` -> `Flow.__Flow_init`.
- Deployment-time flow knobs are init-only:
  - `flowImpl`, `managerRewardPoolFlowRatePpm`, `managerRewardPool`, and `allocationPipeline`.
  - Runtime mutator entrypoints for these knobs are removed.
- Flow authority is split and explicit:
  - `recipientAdmin` governs recipient lifecycle and metadata updates.
  - `flowOperator`/`parent` govern flow-rate mutation.
  - `sweeper` governs held SuperToken sweep.
- Child flow creation via `addFlowRecipient(...)` requires explicit child-role inputs (`recipientAdmin`, `flowOperator`, `sweeper`) at creation time.
- Child flow creation via `addFlowRecipient(...)` also fixes child manager-reward routing (`managerRewardPool` + `managerRewardPoolFlowRatePpm`) at creation time.
- Allocation updates must pass previous-state snapshot/commit validation and strategy allocation checks.
- Allocation-ledger-driven child sync and treasury-driven flow-rate synchronization are part of runtime safety.

### Goal/Budget lifecycle

- Goal and budget treasuries start in funding state, then activate or finalize based on thresholds and deadlines.
- `sync()` is the permissionless best-next-action entrypoint:
  - `Funding`: activate when threshold is met, otherwise expire once windows elapse.
  - `Active`: sync flow-rate while time remains; at/after deadline:
    - goal treasuries resolve pending assertions deterministically (`Succeeded` when truthful, `Expired` when false/invalid, else remain active with zero target flow),
    - budget treasuries open a one-time post-deadline reassert grace when the first pending assertion settles false/invalid; if grace elapses without a new pending assertion (or the grace reassert settles false/invalid), state transitions to `Expired`.
  - Terminal states: no-op.
- Goal active flow-rate targeting is spend-pattern based (linear pattern locked today):
  - raw linear target is `treasuryBalance / timeRemaining`,
  - when the linear target is currently buffer-affordable, sync applies a proactive buffer-derived liquidation-horizon cap before write attempts,
  - write-time fallback ladder remains active on reverts.
- Goal active flow-rate targeting is not coverage-rate-clamped:
  - underwriting enforcement uses budget credit-line recipient gating in `BudgetTCR.syncBudgetTreasuries`,
  - goal target returns zero when distribution pool total units are zero (no enabled recipients).
- Budget credit-line gating uses:
  - exposure meter: `goalFlow.getTotalReceivedByMember(childFlow)`,
  - credit line: `budgetTotalAllocatedStake(budgetTreasury) * executionDuration / coverageLambda`,
  - recipient gating: over-line disables goal-flow recipient (effective units `0`), under-line re-enables and restores saved virtual units,
  - per-item enforcement runs before budget treasury `sync()` during `BudgetTCR.syncBudgetTreasuries`,
  - enforcement is best-effort in batch sync; failures emit `BudgetCreditCapEnforcementFailed` and do not abort other items.
- Budget active flow-rate targeting is trusted-incoming plus balance-spenddown:
  - trusted incoming component: `max(parentFlow.getMemberFlowRate(address(budgetFlow)), 0)`,
  - spenddown component: `treasuryBalance / timeRemaining`,
  - raw budget target is the sum of both components, saturated to `int96.max`,
  - unsolicited third-party inbound streams to the budget flow must not increase the trusted incoming component.
- Budget underwriting premium/slash lifecycle is per-budget escrowed:
  - each budget child flow manager-reward stream is routed to that budget's `PremiumEscrow` at goal-configured `budgetPremiumPpm`,
  - `PremiumEscrow` checkpoints per-underwriter coverage from `BudgetStakeLedger` and accrues premium via balance-index accounting,
  - premium claims are allowed only while parent goal state is `Succeeded`,
  - if premium arrives when total budget coverage is zero, it is recycled to the goal funding path (no orphan premium custody),
  - if the goal expires, escrowed premium can be permissionlessly swept via `burnOnGoalFailure()` to goal flow and burned via terminal residual settlement,
  - on budget terminalization, budget treasury best-effort closes escrow with `(finalState, activatedAt, resolvedAt)` metadata.
- Budget failure slashing semantics are spend-proportional and activation-gated:
  - slash is enabled only when escrow is closed into `Failed` or post-activation `Expired` (`activatedAt != 0`),
  - slash weight derives from `creditDrawn` with spend-formula params (`coverageLambda`, fixed budget `executionDuration`), applies `budgetSlashPpm`, and is capped by strict slash-percent principal (`peakCov * budgetSlashPpm / 1e6`),
  - unresolved spend-formula params revert slash (no exposure-integral fallback mode),
  - slashing is idempotent per underwriter per escrow.
- Slashed value recycle path is routed and observable:
  - `PremiumEscrow` calls per-goal `UnderwriterSlasherRouter`,
  - router executes stake-vault underwriter slashing, attempts cobuild->goal conversion via revnet terminal, upgrades to goal SuperToken,
  - router forwards SuperToken to goal funding path; conversion failures emit events and retain cobuild for later attempts,
- Manual failure is budget-only and controller-gated (`resolveFailure`), with no goal manual-failure entrypoint.
- Goal terminal states are `Succeeded` and `Expired`; resolved-false or invalid post-deadline success assertions finalize to `Expired`.
- Success transitions are assertion-backed:
  - immutable `successResolver` controls assertion registration/clearing,
  - goal `resolveSuccess` is success-resolver-only and requires an active pending truthful assertion id,
  - budget `resolveSuccess` is success-resolver-only and requires an active pending truthful assertion id.
- Budget listing oracle config is hash-only:
  - `oracleConfig.oracleSpecHash` and `oracleConfig.assertionPolicyHash` must both be non-zero.
- Budget success assertion registration is funding-window gated (no registration before `fundingDeadline`).
- Policy C deadline behavior:
  - goal success assertions must be initiated pre-deadline,
  - budget treasuries allow one post-deadline reassert during active reassert grace after a late false-settled pending assertion,
  - success can finalize post-deadline when assertion was initiated pre-deadline, or for budgets via the one-time post-deadline grace reassert.
- Pending assertions block active-state terminalization races only while unresolved.
- Accepted budget removals use activation-locked split semantics:
  - pre-activation removal disables budget success resolution at removal-acceptance and strict-finalizes the budget to terminal `Failed`,
  - activation-locked removal stops forward spend/funding while preserving success eligibility and does not auto-force `Failed`,
  - retry progression for removed activation-locked budgets enforces spend-stop then attempts treasury `sync()`; pre-activation retries remain terminal-only.
- Finalization is state-first and non-bricking:
  - terminal state/timestamp are committed before external settlement side effects,
  - flow stop, residual settlement, deferred-hook settlement, budget premium-escrow close, and stake-vault marking are best-effort during finalize and permissionlessly retryable via terminal-side-effect retries.
- Underwriter withdrawal settlement is caller-scoped (not globally budget-scoped):
  - after `markGoalResolved`, each underwriter must complete `StakeVault.prepareUnderwriterWithdrawal(maxBudgets)` over append-only registered budgets,
  - preparation blocks only that caller when unresolved exposure remains and executes required `PremiumEscrow.slash(caller)` calls for failed/post-activation-expired budgets,
  - `withdrawGoal`/`withdrawCobuild` require successful caller preparation for the current goal-resolution epoch.
- Budget stake ledger is coverage-only accounting; no points/maturation/success-snapshot payout subsystem remains in runtime.
- Terminal residual handling remains callable after finalization (`GoalTreasury.settleLateResidual`, `BudgetTreasury.settleLateResidualToParent`) to absorb late inflows without stranded value.

### TCR/arbitration lifecycle

- Request/challenge/dispute/timeout transitions are explicit and should preserve dispute accounting and status semantics.
- Arbitrator token/arbitrable compatibility is a hard precondition.

## Behavioral Guarantees

- Access-control and governance boundaries are explicit and test-backed.
- Funds-transfer paths must remain deterministic and fail-safe.
- Allocation-driven premium escrow checkpointing is consensus-critical and fail-closed; allocation commits revert on checkpoint failure.
- External hooks and strategies should not silently invalidate core invariants.

## Breaking-Change Policy

Treat as breaking for integrators when changing:
- interface shapes (`src/interfaces/**`, `src/tcr/interfaces/**`),
- lifecycle/state-machine semantics,
- role/permission paths,
- error/event semantics consumed by external systems.

Document such changes in architecture docs and execution plans.

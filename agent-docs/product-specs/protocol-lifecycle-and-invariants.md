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
- Goal allocation child sync is best-effort per target, but account-level child-sync debt fail-closes checkpoint-requiring
  follow-up allocations until debt is cleared (successful sync) or repaired permissionlessly per budget via
  `GoalFlowAllocationLedgerPipeline.repairChildSyncDebt(account, budgetTreasury)`.
- Budget child-sync target discovery is registry-backed:
  - `budgetTreasury.authority()` must point at the owning `BudgetTCR`,
  - `GoalFlowLedgerMode` resolves canonical `childFlow` + child strategy from that registry and still fail-closes when
    the live child flow does not expose exactly one strategy matching stored topology.

### Goal/Budget lifecycle

- Goal and budget treasuries start in funding state, then activate or finalize based on thresholds and deadlines.
- `sync()` is the permissionless best-next-action entrypoint:
  - `Funding`: activate when threshold is met (including post-`fundingDeadline` sync calls while state is still `Funding`), otherwise expire once the funding window has ended and threshold remains unmet.
  - `Active`: sync flow-rate while time remains; at/after deadline:
    - goal treasuries resolve pending assertions deterministically (`Succeeded` when truthful, `Expired` when false/invalid, else remain active with zero target flow),
    - budget treasuries open a one-time post-deadline reassert grace when the first pending assertion settles false/invalid; if grace elapses without a new pending assertion (or the grace reassert settles false/invalid), state transitions to `Expired`.
  - Terminal states: no-op.
- Goal active flow-rate targeting is policy-only and always delegates to `ISpendPolicy.targetFlowRate(SpendContext)`:
  - the current uncapped goal default is `LinearSpendPolicy(includeIncomingRate=false, maxTargetFlowRate=0, syncMode=LinearSpendDownFallback)`,
  - that policy yields raw linear target `treasuryBalance / timeRemaining`,
  - goal sync applies the proactive buffer-derived liquidation-horizon cap only when the configured policy selects `LinearSpendDownFallback`.
- Goal active flow-rate targeting is not coverage-rate-clamped:
  - underwriting enforcement uses budget credit-line recipient gating in `BudgetTCR.syncBudgetTreasuries`,
  - goal target returns zero when distribution pool total units are zero (no enabled recipients),
  - policy context does not include recipient units; it is limited to timing, balance, incoming rate, and current outflow.
- Budget credit-line gating uses:
  - exposure meter: `goalFlow.getTotalReceivedByMember(childFlow)`,
  - insured line: `budgetTotalAllocatedStake(budgetTreasury) * budgetSlashPpm / 1e6`, optionally further bounded by `runwayCap`,
  - recipient gating: over-line disables goal-flow recipient (effective units `0`), under-line re-enables and restores saved virtual units,
  - budget `executionDuration` does not increase insured principal; it only affects budget treasury pacing / lock time,
  - per-item enforcement runs before budget treasury `sync()` during `BudgetTCR.syncBudgetTreasuries`,
  - enforcement is best-effort in batch sync; failures emit `BudgetCreditCapEnforcementFailed` and do not abort other items.
- Budget active flow-rate targeting is policy-only and always delegates to `ISpendPolicy.targetFlowRate(SpendContext)`:
  - the repo-wide default budget deployment is a BudgetTCR-wide `LinearSpendPolicy(includeIncomingRate=true, maxTargetFlowRate=0, syncMode=Capped)`,
  - that policy preserves the current trusted incoming component `max(parentFlow.getMemberFlowRate(address(budgetFlow)), 0)` plus balance spenddown `treasuryBalance / timeRemaining`,
  - raw budget target is the sum of both components, saturated to `int96.max`,
  - default sync mode remains `Capped`, while other configured policies may select `Capped` or `LinearSpendDownFallback`,
  - unsolicited third-party inbound streams to the budget flow must not increase the trusted incoming component.
- Budget underwriting premium/slash lifecycle is per-budget escrowed:
  - each budget child flow manager-reward stream is routed to that budget's `PremiumEscrow` at goal-configured `budgetPremiumPpm`,
  - `PremiumEscrow` checkpoints per-underwriter coverage from `BudgetStakeLedger` and accrues premium via balance-index accounting,
  - premium claims are allowed only while parent goal state is `Succeeded`,
  - if premium arrives when total budget coverage is zero, it is recycled to the goal funding path (no orphan premium custody),
  - if the goal expires, escrowed premium can be permissionlessly swept via `burnOnGoalFailure()` to goal flow and burned via terminal residual settlement,
  - on budget terminalization, budget treasury best-effort closes escrow with `(finalState, activatedAt, resolvedAt)` metadata.
- Community root routing is wrapper-seeded and split-driven:
  - `CobuildPaymentTerminalFactory` is the canonical deployer for the community-routing pair:
    - it deterministically derives the wrapper + hook addresses from `(caller, config, salt)`,
    - deploys the wrapper before hook initialization so `routeSetter` can still be fixed at init time,
    - initializes the hook with the deployed wrapper as the fixed `routeSetter` in the same transaction.
  - `CobuildPaymentTerminal` optionally decodes routing metadata as `abi.encode(uint256[] goalIds, uint32[] weights)`,
    seeds either an explicit route or a historical-default route on `CobuildSplitHook`, and then pays the configured community revnet.
  - `CommunityGoalRegistry` is the canonical onchain source of donor-visible goals:
    - standard community listings use `GeneralizedTCR` request/challenge/arbitration flow with canonical `bytes32(goalId)` item ids,
    - owner-backed system goals can be pinned/unpinned directly,
    - each listed goal carries metadata plus paused/selectable state only.
  - `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury` for community routing:
    - authorized goal-factory versions register deployed treasuries exactly once,
    - treasury identity is immutable per goal id once registered.
  - `CobuildSplitHook` keeps both the wrapper contract `routeSetter`, the `CommunityGoalRegistry` reference, and the
    `GoalDeploymentRegistry` reference fixed from initialization.
  - Explicit routed community pays are the only community flows that record historical routing volume.
  - Empty-metadata wrapper pays fail closed when the seeded historical/default route remains unconsumed after a pay that returned nonzero beneficiary tokens; if the pay returns zero beneficiary tokens, the wrapper clears the unused pending route instead of reverting.
  - `CobuildSplitHook` routes reserved community tokens only during the configured community revnet's controller callback,
    only into registry-selectable child goals, derives market-default routing from registry-selectable goals with observed explicit routed volume,
    uses each goal's deployment-registry-provided treasury sink for raw direct-pay fallback beneficiaries,
    and otherwise fails closed when no usable historical route exists.
- Budget failure slashing semantics are first-loss-principal and activation-gated:
  - slash is enabled only when escrow is closed into `Failed` or post-activation `Expired` (`activatedAt != 0`),
  - slash weight is `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)`,
  - slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on fixed budget
    `executionDuration`,
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
- Accepted budget delistings (on-chain `removeItem`/`finalizeRemovedBudget`) use activation-locked split semantics:
  - pre-activation delisting disables budget success resolution at delist-acceptance and strict-finalizes the budget to terminal `Failed`,
  - activation-locked delisting stops forward spend/funding while preserving success eligibility and does not auto-force `Failed`,
  - retry progression for delisted activation-locked budgets enforces spend-stop then attempts treasury `sync()`; pre-activation retries remain terminal-only,
  - exact-byte relists are rejected once a stack has ever been deployed for that `itemID`; same-byte resubmission is only valid when the earlier request was removed before activation deployed a child-flow recipient.
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
- `AllocationMechanismTCR` enforces `MAX_ACTIVE_MECHANISM_RECIPIENTS = 7`; activation beyond cap reverts and active-recipient
  count decrements when funding stops or finalized removals detach recipients.
- Per-budget mechanism registries initialize with a non-empty initial factory set supplied by the stack deployer; the
  current default stack seeds both `RoundFactory` and `TeamFlowFactory` as immediately allowlisted mechanism
  factories.
- `TeamFlowFactory` deploys a `TeamFlow` manager plus standalone child `CustomFlow` and keeps the existing
  mechanism-funding escrow release path by using that child flow as the payout recipient.
- `TeamFlow` is the child flow's single allocation strategy and equal-split seat manager:
  - seat removal uses hard `removeRecipient` on the child flow rather than enable/disable toggles,
  - re-adding a previously removed member creates a fresh child-flow recipient id instead of reusing the removed one.
- Factory discovery invariants:
  - `BudgetTCRFactory` is the fixed deployment emitter for first-hop budget stack discovery (`BudgetTCRStackDeployedForGoal`).
  - Registered per-budget stack deployers callback into `BudgetTCRFactory` for second-hop child stack and mechanism discovery
    (`BudgetStackDeployed`, `BudgetAllocationMechanismDeployed`), so off-chain discovery can stay factory-address anchored.
  - The same authenticated mechanism callback also authorizes the deployed allocation-mechanism arbitrator in the goal's `JurorSlasherRouter`; budget activation must fail closed if that authorization cannot be applied.
  - Round stacks deployed later through `RoundFactory` keep stake-vault voting but do not participate in juror stake slashing; no round arbitrator router authorization step exists or is required.
- Per-goal `BudgetTCR` is also the canonical runtime topology registry for accepted budgets:
  - activation records `childFlow`, `budgetTreasury`, `premiumEscrow`, shared child strategy, allocation mechanism, and
    allocation-mechanism arbitrator before `BudgetStakeLedger.registerBudget(...)`,
  - `BudgetStakeLedger.registerBudget(...)` reads that topology from goal-flow `recipientAdmin` and still cross-checks
    `budgetTreasury.flow()` plus child-parent wiring before admitting coverage tracking,
  - removed/inactive stacks remain discoverable through `BudgetTCR` topology getters with `active == false`,
  - topology history is single-deployment per item hash: once an `itemID` has produced a real stack, later exact-byte relists fail fast instead of reaching an unactivatable Flow recipient-id reuse path.

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

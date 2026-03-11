# Protocol Lifecycle and Invariants

## Scope

This spec captures stable lifecycle and behavior contracts across Flow, goals/treasury, and TCR/arbitrator modules.

## Lifecycle Contracts

### Flow lifecycle

- Flows initialize through concrete runtime entrypoints (`CustomFlow.initialize`, `TeamFlow.initialize`) -> `Flow.__Flow_initWithRoles`.
- Deployment-time flow knobs are init-only:
  - `flowImpl`, `managerRewardPoolFlowRatePpm`, `managerRewardPool`, and `allocationPipeline`.
  - Runtime mutator entrypoints for these knobs are removed.
- Flow authority is split and explicit:
  - `recipientAdmin` governs recipient lifecycle and metadata updates.
  - `flowOperator`/`parent` govern flow-rate mutation.
  - `sweeper` governs held SuperToken sweep.
- Child flow creation via `addFlowRecipient(...)` requires explicit child-role inputs (`recipientAdmin`, `flowOperator`, `sweeper`) at creation time.
- Child flow creation via `addFlowRecipient(...)` also fixes child manager-reward routing (`managerRewardPool` + `managerRewardPoolFlowRatePpm`) at creation time.
- Flow init and child-flow creation both take a single configured `IAllocationStrategy`; the runtime strategy is exposed via `strategy()`.
- Allocation updates must pass previous-state snapshot/commit validation and strategy allocation checks.
- Allocation-ledger-driven child sync and treasury-driven flow-rate synchronization are part of runtime safety.
- Goal allocation child sync is best-effort per target, but account-level child-sync debt fail-closes checkpoint-requiring
  follow-up allocations until debt is cleared (successful sync) or repaired permissionlessly per budget via
  `GoalFlowAllocationLedgerPipeline.repairChildSyncDebt(account, budgetTreasury)`.
- Budget child-sync target discovery is registry-backed:
  - `budgetTreasury.authority()` must point at the owning `BudgetTCR`,
  - `GoalFlowLedgerMode` resolves canonical `childFlow` + child strategy from that registry and still fail-closes when
    the live child flow's configured `strategy()` does not match stored topology.

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
  - `PremiumEscrow` goal-flow receipt baseline/checkpoint reads are accounting-critical and fail closed on read failure,
  - premium claims are allowed only while parent goal state is `Succeeded`,
  - if premium arrives when total budget coverage is zero, it is recycled to the goal funding path (no orphan premium custody),
  - if the goal expires, escrowed premium can be permissionlessly swept via `burnOnGoalFailure()` to goal flow and burned via terminal residual settlement,
  - on budget terminalization, budget treasury best-effort closes escrow with `(finalState, activatedAt, resolvedAt)` metadata.
- Community root routing is wrapper-seeded and split-driven:
  - `CobuildPaymentTerminalFactory` is the canonical deployer for the community-scoped split hook:
    - it deterministically derives the split-hook clone address from `(caller, goalRegistry, routeSetter, salt)`,
    - deploys only the split hook,
    - initializes the hook with the shared wrapper as the fixed `routeSetter`.
  - `CobuildPaymentTerminal` optionally decodes routing metadata as `abi.encode(uint256[] goalIds, uint32[] weights)`,
    seeds an explicit route on `CobuildSplitHook` only when the caller selected goals, pays through the registered
    community config, and synchronously flushes reserved-token splits through the community controller when that pay
    created reserved tokens.
  - Community registration is owner-gated per community revnet and must bind the split hook, payment token,
    payment-source revnet, and direct-native toggle against the registry + directory wiring before the wrapper can pay.
  - `CommunityGoalRegistry` is the canonical onchain source of donor-visible goals:
    - standard community listings use `GeneralizedTCR` request/challenge/arbitration flow with canonical `bytes32(goalId)` item ids,
    - owner-backed system goals can be pinned/unpinned directly with configured `floorPpm`,
    - total configured system-goal floor is capped at `1_000_000` ppm,
    - each listed goal carries metadata plus paused/selectable state, and system goals additionally expose `floorPpm`.
  - `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury` for community routing:
    - authorized goal-factory versions register deployed treasuries exactly once,
    - treasury identity is immutable per goal id once registered.
  - `CobuildTerminal` is the canonical shared goal funding terminal:
    - it resolves the goal's payment token and payment-source revnet from the registered goal treasury + stake vault at pay time,
    - native ETH funding must convert through the resolved payment-source revnet before forwarding to the goal's primary payment-token terminal.
  - `CobuildSplitHook` keeps both the wrapper contract `routeSetter`, the `CommunityGoalRegistry` reference, and the
    `GoalDeploymentRegistry` reference fixed from initialization.
  - `CobuildSplitHook` applies configured system-goal floor routing first on every controller callback and routes those
    slices to canonical goal-treasury beneficiaries.
  - Explicit routed community pays only route the discretionary remainder after that floor-first pass.
  - Only discretionary explicit routed community pays record historical routing volume.
  - Wrapper-routed community pays snapshot any preexisting controller reserved-token backlog, route only the current
    pay's newly created reserved-token delta through the pending route, and defer the older backlog to permissionless
    historical flushing so a new user route cannot capture earlier backlog.
  - `CobuildSplitHook` only accepts controller callbacks whose split percent is the full reserved-token bucket
    (`JBConstants.SPLITS_TOTAL_PERCENT`); fractional reserved-split configs are invalid because pending-route/backlog
    accounting assumes one coherent callback bucket.
  - If a wrapper-routed pay creates reserved tokens, the wrapper must force same-transaction split delivery and
    pending-route consumption for that newly created delta.
  - If a wrapper-routed pay creates no reserved tokens, the wrapper clears the unused pending route instead of leaving
    stale routing state behind.
  - Hook-managed historical backlog is discretionary-only and is retried through a paginated permissionless flush path (`flushHistoricalBacklog(maxGoalCount)`), so backlog liveness is chunkable instead of all-or-nothing.
  - `CobuildSplitHook` routes reserved community tokens only during the configured community revnet's controller callback,
    routes system-floor slices into currently selectable system goals using deployment-registry-provided treasury sinks,
    only routes discretionary explicit selections into registry-selectable child goals for wrapper-selected routes,
    derives backlog flush routing from selectable non-system goals with observed discretionary explicit volume, uses
    each goal's deployment-registry-provided treasury sink for backlog flush beneficiaries, and otherwise defers
    discretionary historical backlog on-hook for later permissionless retry when no usable historical route exists.
  - If a configured system goal is paused or otherwise not selectable, its floor share falls back into the
    discretionary remainder instead of reverting the community callback.
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
- `TeamFlowFactory` deploys a single `TeamFlow` payout flow and keeps the existing
  mechanism-funding escrow release path by using that deployed `TeamFlow` runtime as the payout recipient.
- `TeamFlow` is a self-administered payout flow with fixed per-seat units:
  - seat removal uses hard `removeRecipient` on the `TeamFlow` runtime rather than enable/disable toggles,
  - re-adding a previously removed member creates a fresh TeamFlow recipient id instead of reusing the removed one.
- Factory discovery invariants:
  - `BudgetTCRFactory` is the fixed deployment emitter for first-hop budget stack discovery (`BudgetTCRStackDeployedForGoal`).
  - `BudgetTCRFactory` treats submission-deposit capability probing as required deployment wiring: clean `supportsEscrowBonding() == false` preserves manual deposits, while missing/reverting probes fail deployment.
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

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
  - accepted open-preset removal of an already-activated budget is detachment, not implicit fail-close: parent funding stops immediately, but already received funds stay governed by the treasury's normal terminal path.
  - goal expiry removes premium upside by making escrowed premium sweepable/burnable, but it does not by itself create a new principal-slash path outside budget terminalization.
- Community root routing is canonical-terminal-seeded and split-driven:
  - `CobuildCommunityTerminalFactory` is the canonical deployer for the community-scoped split hook:
    - it deterministically derives the split-hook clone address from `(caller, goalRegistry, routeSetter, salt)`,
    - deploys the split hook,
    - initializes the hook with the shared terminal as the fixed `routeSetter`,
    - fail-closes registration unless the community revnet's live reserved-token split group already contains exactly one nonzero split whose `hook` is that same predicted address for the current ruleset,
    - deployment orchestration must atomically set that live reserved split to the predicted hook address and call `deployFor(...)`, otherwise permissionless reserved-token flushes can mint into the predicted address before code exists,
    - completes same-transaction community registration on that terminal through the terminal's approved-factory path, while standalone registration remains a direct owner call on the shared terminal.
  - `CobuildCommunityTerminal` optionally decodes community pay metadata as
    `abi.encode(uint256[] goalIds, uint32[] weights, bytes jbMetadata)`,
    seeds an explicit route on `CobuildSplitHook` only when the caller selected goals, forwards `jbMetadata` unchanged
    into terminal-store accounting and pay-hook `payerMetadata`, pays through the registered community config, and
    synchronously flushes reserved-token splits through the community controller when that pay created reserved tokens.
  - `CobuildCommunityTerminal.cashOutTokensOf(...)` is the canonical upward redemption primitive for registered community layers:
    - supported reclaim assets are the registered payment token and native ETH,
    - it records reclaim through terminal-store cash-out accounting, burns the holder's community tokens, transfers held reclaim liquidity, fulfills cash-out hooks, and intentionally requires `holder == msg.sender`.
  - Community registration is gated by the community project owner per revnet and must bind the split hook, payment token,
    payment-source revnet, and direct-native toggle against immutable registry + directory wiring before the terminal can pay; the supported entrypoints are direct owner calls and the approved factory path only.
  - If `directNativeAllowed`, community registration must pin `paymentSourceRevnetId == communityRevnetId`.
  - Community registration must also prove on-chain that the current reserved-token split group will call the registered
    hook by requiring exactly one live nonzero split whose `hook` matches the registered split hook.
  - Registered communities must point both their native ETH terminal and registered payment-token terminal at the shared
    `CobuildCommunityTerminal`; sidecar-only directory wiring is invalid.
  - `CommunityGoalRegistry` is the canonical onchain source of donor-visible goals:
    - standard community listings use `GeneralizedTCR` request/challenge/arbitration flow with canonical `bytes32(goalId)` item ids,
    - the registry is ownerless and does not expose privileged system goals or pause controls,
    - each listed goal carries donor-visible metadata only, while selectability is derived from canonical deployment, funding context, terminal presence, and live `GoalTreasury.canAcceptHookFunding()` status,
    - add-item validation best-effort calls `goal.sync()` before lifecycle checks and rejects terminal/prunable goals,
    - terminal goals can be permissionlessly pruned from the donor-visible listed set via `pruneTerminalGoal(goalId)`, which also best-effort calls `goal.sync()` before deciding prunability.
  - `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury` for community routing:
    - authorized goal-factory versions register deployed treasuries exactly once,
    - treasury identity is immutable per goal id once registered.
  - `CobuildGoalTerminal` is the canonical shared goal funding terminal:
    - it resolves the goal's payment token and payment-source revnet from the registered goal treasury + stake vault at pay time,
    - native ETH funding must convert through the resolved payment-source revnet before forwarding to the goal's primary payment-token terminal.
  - `CobuildExitRouter` is the canonical shared user exit surface:
    - `exitToCommunityToken(...)` cashes out a goal into its immediate upstream community denomination and rejects any first hop that is not a registered community layer,
    - `exitToCobuildToken(...)` and `exitToEth(...)` keep walking registered community lineage onchain until they reach COBUILD or a direct-native root, and each community hop must settle through `CobuildCommunityTerminal`,
    - public callers do not supply arbitrary route arrays; route inference is derived from canonical goal and community terminal config.
  - `CobuildSplitHook` keeps both the terminal contract `routeSetter`, the `CommunityGoalRegistry` reference, and the
    `GoalDeploymentRegistry` reference fixed from initialization.
  - `CobuildSplitHook` routes only its explicit callback slice for terminal-seeded pending routes into the selected registry-selectable goals.
  - All explicit routed community pays record the hook-routed amount into per-goal routing scores.
  - Canonical-terminal-routed community pays snapshot the Cobuild hook's share of any preexisting controller reserved-token backlog, route only the current
    pay's newly created hook-slice delta through the pending route, and defer the older hook backlog to permissionless
    historical flushing so a new user route cannot capture earlier backlog.
  - Fractional reserved-split configs are valid as long as the live split group contains exactly one nonzero entry pointing at the registered Cobuild hook.
  - If a canonical-terminal-routed pay creates reserved tokens, the terminal must force same-transaction split delivery and
    pending-route consumption whenever the Cobuild hook's routed slice increased.
  - If a canonical-terminal-routed pay creates no reserved tokens, the terminal clears the unused pending route instead of leaving
    stale routing state behind.
  - Hook-managed historical backlog is discretionary-only and is retried through a paginated permissionless flush path (`flushHistoricalBacklog(maxGoalCount)`), so backlog liveness is chunkable instead of all-or-nothing.
  - `CobuildSplitHook` routes reserved community tokens only during the configured community revnet's controller callback,
    only routes explicit selections into registry-selectable child goals for terminal-selected routes,
    derives backlog flush routing from selectable goals with lazily decaying explicit-route scores whose half-life is
    enforced on global 30-day season boundaries, uses
    each goal's deployment-registry-provided treasury sink for backlog flush beneficiaries, and otherwise defers
    historical backlog on-hook for later permissionless retry when no usable historical route exists.
- Budget failure slashing semantics are first-loss-principal and activation-gated:
  - slash is enabled only when escrow is closed into `Failed` or post-activation `Expired` (`activatedAt != 0`),
  - slash weight is `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)`,
  - slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on fixed budget
    `executionDuration`,
  - slashing is idempotent per underwriter per escrow.
  - budgets that never activated (`activatedAt == 0`), including funding-window misses and pre-activation removals, are not slashable and lose upside only.
  - activated budgets that were later delisted from the open preset keep normal terminal economics after detachment: terminal `Succeeded` preserves success-side premium eligibility (still subject to goal success), while terminal `Failed` or `Expired` remain slashable.
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
- Success document retrieval is canonical and onchain:
  - goal and budget treasuries still store only `successOracleSpecHash` / `successAssertionPolicyHash`,
  - `UMATreasurySuccessResolver.assertSuccess(...)` requires both hashes to already exist in `SuccessAssertionDocumentRegistry`,
  - non-empty evidence text is auto-registered in that registry under `keccak256(bytes(evidence))`,
  - the UMA claim and `SuccessAssertionRequested` event emit the registry address plus canonical `specHash` / `policyHash` / `evidenceHash`, not just raw prose.
- Budget listing oracle config is hash-only:
  - `oracleConfig.oracleSpecHash` and `oracleConfig.assertionPolicyHash` must both be non-zero.
- Budget success assertion registration is funding-window gated (no registration before `fundingDeadline`).
- Policy C deadline behavior:
  - goal success assertions must be initiated pre-deadline,
  - budget treasuries allow one post-deadline reassert during active reassert grace after a late false-settled pending assertion,
  - success can finalize post-deadline when assertion was initiated pre-deadline, or for budgets via the one-time post-deadline grace reassert.
- Pending assertions block active-state terminalization races only while unresolved.
- Open-preset accepted budget delistings (on-chain `removeItem`/`finalizeRemovedBudget`) use activation-locked split semantics:
  - pre-activation delisting disables budget success resolution at delist-acceptance and strict-finalizes the budget to terminal `Failed`,
  - activation-locked delisting is detach semantics, not implicit fail-close,
  - activation-locked delisting removes the parent recipient / stake-ledger registration so no new parent funding or governance-backed expansion enters through the open preset after removal,
  - activation-locked delisting force-zeroes forward spend immediately but preserves already received funds and any pending success assertion,
  - activation-locked delisting keeps normal treasury terminal progression (`Succeeded`, `Failed`, or `Expired`) through later `sync()` / `retryRemovedBudgetResolution(...)` handling rather than auto-forcing `Failed`,
  - retry progression for delisted activation-locked budgets enforces spend-stop then attempts treasury `sync()`; pre-activation retries remain terminal-only,
  - exact-byte relists are rejected once a stack has ever been deployed for that `itemID`; same-byte resubmission is only valid when the earlier request was removed before activation deployed a child-flow recipient.
- Managed-preset controller removals use fail-closed terminalization:
  - removals use the treasury's controller-only removal fail-close path for both pre-activation and activated budgets,
  - the controller removes the goal-flow recipient, marks the topology inactive, and best-effort syncs the goal treasury inline in the same removal transaction,
  - the treasury skips its redundant controller-prune callback during that removal finalization, while later `retryTerminalSideEffects()` calls still retry the normal terminal side-effect set,
  - managed `syncBudgetTreasuries(...)` locally prunes newly terminal budgets after a successful treasury `sync()` instead of depending on a reentrant treasury callback into the controller,
  - future `sync()` calls remain terminal no-ops after removal.
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

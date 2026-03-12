# Cobuild Protocol Architecture

Last updated: 2026-03-11

See `agent-docs/index.md` for the canonical documentation map.

## Repository Layout

```text
cobuild-protocol/
├── src/
│   ├── Flow.sol                      # core flow engine
│   ├── flows/CustomFlow.sol          # concrete flow deployment/allocation entrypoint
│   ├── library/                      # flow math/recipient/allocation/helpers
│   ├── goals/                        # goal and budget treasury + stake/reward modules
│   ├── hooks/                        # revnet split hook
│   ├── allocation-strategies/        # strategy plugins for allocation weighting
│   ├── tcr/                          # TCR + arbitrator + storage/utils
│   ├── interfaces/                   # protocol interfaces
│   └── storage/                      # upgrade-safe storage layouts
├── test/                             # flow, goals, tcr/arbitrator, invariants, mocks
├── agent-docs/                       # durable docs, references, plans, generated inventory
├── scripts/                          # build/test/docs/static-analysis helpers
└── .github/workflows/                # CI, slither, doc-gardening
```

## Domain Model

### Flow system

- Base engine: `src/Flow.sol`.
- Concrete runtimes: `src/flows/CustomFlow.sol` and `src/teamflow/TeamFlow.sol`.
- Core libraries: `src/library/FlowInitialization.sol`, `src/library/FlowAllocations.sol`, `src/library/FlowRates.sol`, `src/library/FlowPools.sol`, `src/library/FlowRecipients.sol`.
- Storage layout boundary: `src/storage/FlowStorage.sol`.
- Child runtime deployment uses EIP-1167 minimal clones (`Clones.clone`) for initializer-based setup and isolated storage per flow instance.
- Flow runtimes are intentionally non-upgradeable and expose no runtime upgrade selector.

### Goal and treasury system

- Shared treasury mechanics base: `src/goals/TreasuryBase.sol`.
- Goal lifecycle treasury: `src/goals/GoalTreasury.sol`.
- Canonical deployed-goal registry: `src/goals/GoalDeploymentRegistry.sol`.
- Budget lifecycle treasury: `src/goals/BudgetTreasury.sol`.
- Optional treasury spend-policy modules: `src/goals/policies/*.sol`.
- Goal stake vault: `src/goals/StakeVault.sol`.
- Pluggable budget controllers / topology registries:
  - `src/tcr/BudgetTCR.sol` (open preset)
  - `src/goals/ManagedBudgetController.sol` (managed preset)
- Budget gating boundary: `src/interfaces/IBudgetGatePolicy.sol` plus concrete policies under `src/goals/policies/*.sol`.
- Goal/vault helper libraries: `src/goals/library/*.sol` (treasury flow/donation helpers plus extracted stake/slash math modules).
- Allocation strategies:
  - `src/goals/StakeVault.sol` (open-preset goal allocator plus shared funding / coverage vault).
  - `src/allocation-strategies/SingleAllocatorStrategy.sol` (managed-preset goal allocator; allocator identity is the controller contract).
  - `src/allocation-strategies/BudgetFlowRouterStrategy.sol` (open-preset child-budget strategy backed by `BudgetStakeLedger` stake checkpoints).
  - `src/allocation-strategies/BudgetSingleAllocatorStrategy.sol` (managed-preset child-budget strategy scoped to one budget treasury flow).
- Budget premium / risk modules:
  - `src/goals/PremiumEscrow.sol` (open preset)
  - `src/goals/NullPremiumEscrow.sol` (managed preset)
- Managed budget stack deployer: `src/goals/ManagedBudgetControllerStackDeployer.sol`.
- Underwriter slash routing + conversion path: `src/goals/UnderwriterSlasherRouter.sol`.
- Revnet funding ingress hook: `src/hooks/GoalRevnetSplitHook.sol`.
- Shared goal funding terminal: `src/juicebox/CobuildGoalTerminal.sol`.
- Community reserved-token routing layer: `src/hooks/CobuildSplitHook.sol`, `src/juicebox/CobuildCommunityTerminal.sol`, `src/juicebox/CobuildCommunityTerminalFactory.sol`.

### TCR and arbitration system

- TCR core: `src/tcr/GeneralizedTCR.sol`.
- Arbitrator: `src/tcr/ERC20VotesArbitrator.sol` (supports default ERC20Votes mode and optional stake-vault-backed juror mode).
- `GeneralizedTCR` and `ERC20VotesArbitrator` are deployed as direct, non-upgradeable runtime instances.
- Invalid/no-vote arbitrator round rewards route to a configured sink (`invalidRoundRewardSink`).
- Budget curation extension:
  - `src/tcr/BudgetTCR.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/BudgetTCRFactory.sol`
  - `src/tcr/AllocationMechanismTCR.sol` (per-budget mechanism registry; new stacks seed both `RoundFactory` and
    `TeamFlowFactory`)
  - `src/teamflow/TeamFlow.sol`, `src/teamflow/TeamFlowFactory.sol` (equal-split team payout mechanism family)
- Community goal curation extension:
  - `src/tcr/CommunityGoalRegistry.sol`
- Budget listing validation helpers:
  - `src/tcr/library/BudgetTCRValidationLib.sol`
- Storage and helpers: `src/tcr/storage/*.sol`, `src/tcr/library/TCRRounds.sol`, `src/tcr/utils/*.sol`, `src/tcr/strategies/*.sol`.

### Deployment-time presets

- The recursive-flow substrate is universal. `Flow`, `CustomFlow`, `GoalFlowAllocationLedgerPipeline`, `GoalTreasury`, `BudgetTreasury`, and `StakeVault` are reused by both presets without runtime `isManaged` branching.
- Control-plane modules are chosen at deploy time by `GoalFactory`.
- `StakeVault` remains the funding vault in both presets, but it is not always the allocator.

Open preset
- Goal allocator: `StakeVault`
- Budget controller / topology registry: `BudgetTCR`
- Budget gate policy: `StakeCoverageGatePolicy` through `IBudgetGatePolicy`
- Budget child strategy: shared `BudgetFlowRouterStrategy`
- Premium / risk module: `PremiumEscrow`
- Mechanism layer: `AllocationMechanismTCR`

Managed preset
- Goal allocator: `SingleAllocatorStrategy`
- Goal allocator identity: `ManagedBudgetController`
- Budget controller / topology registry: `ManagedBudgetController`
- Budget gate policy: current preset wiring uses `NoopBudgetGatePolicy`
- Budget child strategy: `BudgetSingleAllocatorStrategy`
- Budget child allocator identity: `ManagedBudgetController`
- Premium / risk module: `NullPremiumEscrow`
- Budget child `recipientAdmin`: `ManagedBudgetController`
- No advisory TCR and no managed mechanism controller in this pass

## Cross-Cutting Invariants

1. Upgrade and storage safety
- Flow runtimes expose no upgrade path at runtime (no upgrade selector is exposed);
  child instances are deployed as EIP-1167 minimal clones.
- Allocation strategies and TCR/arbitrator runtimes are deployed as direct contract instances (no runtime proxy upgrade path).
- Runtime trust assumptions therefore exclude owner-controlled implementation upgrades across flow strategies, TCR, and arbitrator modules.

2. Funds flow correctness
- Hook/treasury/flow/vault paths should preserve accounting and state transition invariants.
- Goal and budget treasuries expose permissionless underlying-only donation ingress:
  - `donateUnderlyingAndUpgrade(amount)` pulls underlying, upgrades, and forwards SuperToken into the managed flow.
  - Goal treasury donation receipts increment `totalRaised` (telemetry); budget treasury donation receipts are balance-only.
- Goal treasury min-raise lifecycle checks are balance-based (`superToken.balanceOf(flow)`), so direct flow transfers can satisfy activation thresholds.
- Shared treasury mechanics are centralized in `TreasuryBase` for donation ingress, treasury balance reads, and flow-rate zeroing helpers; lifecycle policy remains treasury-specific.
- Treasury flow-rate invariants are intentionally split:
  - Goal treasury is policy-only: initialization requires a nonzero `spendPolicy`, target math always delegates to
    `ISpendPolicy`, and current uncapped goal behavior is expressed by `LinearSpendPolicy(includeIncomingRate=false,
    maxTargetFlowRate=0, syncMode=LinearSpendDownFallback)`.
    Goal sync still uses the linear-spenddown fallback writer when the policy selects `LinearSpendDownFallback`, so
    balance-driven targets retain proactive buffer-derived liquidation-horizon capping and best-effort writes
    (target, fallback bounded, then zero on persistent write failure). Goal sync still does not apply coverage-based
    speed clamping; it only returns zero target when the distribution pool has zero units.
  - Budget treasury is also policy-only: initialization requires a nonzero `spendPolicy`, target math always delegates
    to `ISpendPolicy`, and the repo-wide default budget behavior is now an explicit BudgetTCR-wide
    `LinearSpendPolicy(includeIncomingRate=true, maxTargetFlowRate=0, syncMode=Capped)`.
    That preserves the current trusted incoming plus balance spenddown target:
    - trusted incoming component from parent member flow-rate (`max(parent.getMemberFlowRate(child), 0)`),
    - linear balance spenddown component (`treasuryBalance / timeRemaining`),
    - total target saturated to `int96.max` and applied with capped best-effort writes.
  - Policy context is now treasury-topology-agnostic and contains only timing/balance/flow fields
    (`nowTs`, `activatedAt`, `deadline`, `treasuryBalance`, `timeRemaining`, `incomingRate`,
    `currentOutflowRate`); recipient units are not part of `ISpendPolicy.SpendContext`.
- Open-preset budget credit-line eligibility is enforced in `BudgetTCR.syncBudgetTreasuries` through goal-flow recipient gating:
  - cumulative exposure meter is `goalFlow.getTotalReceivedByMember(childFlow)`,
  - insured line is slashable first-loss principal `budgetTotalAllocatedStake(budgetTreasury) * budgetSlashPpm / 1e6`,
  - optional `runwayCap` remains an additional lower ceiling on cumulative received funding,
  - over-limit recipients are disabled (`setRecipientEnabled(..., false)`) so effective pool units are forced to zero,
  - recipients are re-enabled once exposure is back under line after additional coverage credit,
  - budget `executionDuration` no longer increases insured principal; it only affects downstream treasury pacing/lock time,
  - enforcement runs before per-budget treasury `sync()` in each batch iteration so the same cycle observes the updated gate state,
  - enforcement is best-effort per item; external-call failures emit `BudgetCreditCapEnforcementFailed` and batch sync continues.
- Open-preset underwriting premium/slash routing is hard-cutover:
  - each budget child flow manager-reward stream is routed to that budget's `PremiumEscrow` at `budgetPremiumPpm`,
  - `PremiumEscrow` premium entitlement uses a balance-index over live `BudgetStakeLedger` coverage checkpoints (no snapshot-only settlement),
  - `PremiumEscrow` goal-flow receipt baseline/checkpoint reads are accounting-critical and fail closed on read failure (no zero-baseline or silent checkpoint-skip fallback),
  - premium claims are gated on goal success (`GoalTreasury.state() == Succeeded`),
  - premium inflow with zero total budget coverage is recycled to goal funding via goal flow (no stranded/orphan premium),
  - on goal `Expired`, `PremiumEscrow.burnOnGoalFailure()` sweeps escrowed premium to goal flow and best-effort triggers `GoalTreasury.settleLateResidual()` burn settlement,
  - on terminal budget failure after activation (`Failed` or post-activation `Expired`), `PremiumEscrow` treats `creditDrawn` as first-loss principal attributed to each underwriter and slashes `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)`, routing through the per-goal underwriter slasher router,
  - slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on budget
    `executionDuration`.
- Managed-preset risk wiring keeps the same controller/treasury/escrow seam without live premium accounting:
  - manager-reward stream routes to `NullPremiumEscrow`,
  - managed controller wiring now leaves budget-ledger/slasher references unset by default, while `NullPremiumEscrow` keeps the `IPremiumEscrow` seam with only budget-treasury/goal-flow identity and ignores ledger/slasher inputs,
  - claim, slash, burn-on-failure, and close side effects are intentional no-ops,
  - live routing does not depend on underwriter-weight coverage semantics to enable active managed budgets.
- Budget TCR deployment remains a trusted-core path:
  - `BudgetTCRFactory` may preserve manual registry deposits when a strategy cleanly reports `supportsEscrowBonding() == false`,
  - capability probe failures or missing capability interfaces now fail deployment fast instead of silently downgrading escrow-bond economics.
- Underwriter slash recycling path:
  - `UnderwriterSlasherRouter` is configured as StakeVault underwriter slasher and receives slashed goal/cobuild tokens,
  - router best-effort converts cobuild -> goal token via goal revnet terminal (conversion failures are observable and retained),
  - router upgrades goal token to goal SuperToken and forwards to goal funding path (goal flow/treasury target).
  - post-goal-resolution stake withdrawals are caller-prepared (not globally gated): each underwriter must run
    `StakeVault.prepareUnderwriterWithdrawal(maxBudgets)` to traverse append-only registered budgets and execute
    required premium-escrow slashes before `withdrawGoal`/`withdrawCobuild` unlock for that caller.
- `GoalRevnetSplitHook` is controller-gated and treasury-state derived:
  - If `goalTreasury.canAcceptHookFunding()`, reserved inflow funds the goal flow.
  - If treasury state is `Succeeded` and minting is still open, reserved inflow is processed by the success-settlement burn path.
  - If treasury is terminal and success-settlement mode is closed, reserved inflow is processed through treasury terminal settlement policy.
  - If treasury funding is closed but still nonterminal, reserved inflow is deferred on treasury until terminal settlement is known.
- Community reserved-token routing is canonical-terminal-seeded and split-driven:
  - `CobuildCommunityTerminalFactory` is the canonical deployment path for the community-scoped `CobuildSplitHook`:
    - it deterministically derives the split-hook clone address from caller + goal-registry + shared route-setter + salt,
    - deploys the split hook,
    - initializes `CobuildSplitHook` with the shared `CobuildCommunityTerminal` as its fixed `routeSetter`,
    - fail-closes registration unless the community revnet's live reserved-token split group already contains exactly one nonzero split whose `hook` is that same predicted address for the current ruleset,
    - deployment orchestration must atomically set that live reserved split to the predicted hook address and call `deployFor(...)`, otherwise permissionless reserved-token flushes can mint into the predicted address before code exists,
    - completes same-transaction community registration on that terminal through the terminal's approved-factory path, while standalone registration remains a direct project-owner call on the shared terminal.
  - `CobuildCommunityTerminal` is a shared community payment terminal:
    - it must be the community revnet's canonical `DIRECTORY` primary terminal for both native ETH and the registered payment token before registration succeeds,
    - it must also prove on-chain that `controller.sendReservedTokensToSplitsOf(communityRevnetId)` will hit the registered hook by validating that the current reserved split group contains exactly one nonzero split for that hook,
    - each community binds `(splitHook, paymentToken, paymentSourceRevnetId, directNativeAllowed)` exactly once either through a direct community-project-owner call or the approved factory path,
    - `pay(...).metadata` now carries `abi.encode(uint256[] goalIds, uint32[] weights, bytes jbMetadata)` so one-shot explicit routing and downstream JB payer metadata travel together,
    - when `directNativeAllowed` is enabled, registration requires `paymentSourceRevnetId == communityRevnetId`,
    - native ETH either records a canonical JB pay directly on that terminal when `directNativeAllowed` is enabled or first buys the configured payment token from `paymentSourceRevnetId`,
    - if the upstream native terminal is this same shared terminal, the conversion path stays internal instead of re-entering through an external `pay(...)` call,
    - direct payment-token pays are likewise recorded on the shared terminal without the intermediate conversion step,
    - community pays are recorded through the JB terminal store so pause/weight/base-currency rules and pay-hook fulfillment stay aligned with standard terminal semantics,
    - after the community pay, the terminal synchronously calls the community controller's `sendReservedTokensToSplitsOf(...)` when that pay created reserved tokens.
  - `CommunityGoalRegistry` is the canonical onchain source of donor-visible goals:
    - community-listed goals go through `GeneralizedTCR` request/challenge/arbitration flow using canonical `bytes32(goalId)` item IDs,
    - the registry is ownerless and does not expose privileged system goals or pause controls,
    - each listing carries donor-visible metadata only; selectability is derived from canonical goal deployment, funding context, terminal presence, and live `GoalTreasury.canAcceptHookFunding()` status,
    - add-item validation best-effort calls `goal.sync()` before lifecycle checks and rejects terminal/prunable goals,
    - terminal goals can be permissionlessly pruned from the donor-visible listed set via `pruneTerminalGoal(goalId)`, which also best-effort calls `goal.sync()` before deciding prunability.
  - `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury`:
    - `GoalFactory` registers each deployed goal treasury exactly once,
    - owner-authorized future goal-factory versions can register into the same registry over time,
    - treasury identity is immutable per goal id once registered.
  - `CobuildGoalTerminal` is the shared goal funding terminal:
    - it resolves each goal's payment token and source revnet from the registered goal treasury + stake vault at pay time,
    - native ETH pays the resolved source revnet's native terminal to acquire the goal's funding token before forwarding,
    - direct payment-token funding uses the same resolved token and forwards to the goal's primary terminal for that token.
  - `CobuildSplitHook` is controller-gated for the configured community revnet, keeps only a fixed init-time
    contract `routeSetter` plus fixed init-time goal-registry reference and deployment-registry reference, validates
    explicit routes against `CommunityGoalRegistry.isSelectable(goalId)`, routes only its explicit callback slice into the
    selected goals, records the routed slice into lazy decaying routing scores whose half-life is enforced on
    global 30-day season boundaries, and routes backlog only through the paginated permissionless backlog-flush path.
  - Canonical-terminal-routed community pays snapshot the Cobuild hook's share of any preexisting controller backlog before
    the pay so a user-selected route cannot capture earlier backlog.
  - The Cobuild hook can coexist with sibling reserved splits. Fractional reserved-split configs are valid as long as the
    live split group contains exactly one nonzero split pointing at the registered hook.
  - If the canonical-terminal pay creates reserved tokens, the terminal forces same-transaction split delivery; explicit-route
    pending state must be consumed in that same transaction whenever the Cobuild hook's slice increased.
  - If an explicit canonical-terminal pay creates no reserved tokens, the terminal clears the unused pending route instead of
    leaving stale routing state behind.
  - Empty-metadata canonical-terminal pays do not seed any pending route. Any reserved tokens created by that pay are flushed into
    hook-managed backlog for later permissionless historical routing.
  - Raw direct community pays and all controller callbacks without a pending explicit route defer the full amount into
    hook-managed backlog instead of routing it inline. Backlog flushes use current decayed explicit-route weights and
    pay each child goal terminal with that goal's deployment-registry-provided treasury as beneficiary; backlog flushes
    do not mutate the historical routing signal.
- Budget finalization is state-first: it commits terminal state, then best-effort attempts residual child-flow settlement back to the parent goal flow.
- Goal finalization is state-first: it commits terminal state, then best-effort attempts residual goal-flow settlement:
  - `Succeeded`: burn 100% via controller.
  - `Expired`: burn 100% via controller.
- Goal and budget terminal side effects are permissionlessly retryable via `retryTerminalSideEffects()`.
- Goal terminal-state residual policy is reusable post-finalize via `settleLateResidual` to process late budget/stream inflows.
- Budget terminal-state residual sweep is reusable post-finalize via `settleLateResidualToParent` to process late child-flow inflows.
- Goal success resolution is assertion-backed and does not depend on legacy reward-snapshot finalization paths.
- Permissionless `sync()` is the canonical lifecycle progression path:
  - `Funding`: activate when threshold is met, otherwise expire once funding/deadline windows elapse.
  - `Active`: sync flow-rate while time remains; at/after deadline:
    - goal treasury resolves pending assertions deterministically (`Succeeded` when truthful, `Expired` when false/invalid, otherwise remain active with zero target flow),
    - budget treasury keeps single-slot pending assertions but opens a one-time post-deadline reassert grace when the first pending assertion settles false/invalid; if grace elapses without a new pending assertion (or the grace reassert also settles false/invalid), it expires.
  - Terminal states: no-op.
- Terminal side effects that failed during finalize are retried through explicit permissionless entrypoints (`retryTerminalSideEffects`), not via terminal `sync()` no-op behavior.
- Manual failure is budget-only and authority-gated:
  - budget treasury `resolveFailure` is controller-only and deadline-gated (`Funding` after `fundingDeadline`, `Active` at/after `deadline`).
  - goal treasury exposes no manual failure entrypoint.
- Success resolution is assertion-backed:
  - immutable `successResolver` (per treasury) controls `registerSuccessAssertion`/`clearSuccessAssertion`,
  - goal treasury `resolveSuccess` is success-resolver-only and succeeds only when the pending assertion verifies truthful,
  - budget treasury `resolveSuccess` is success-resolver-only and succeeds only when the pending assertion verifies truthful.
- Budget listing oracle config is hash-only:
  - `BudgetTCRValidationLib` requires non-zero `listing.oracleConfig.oracleSpecHash` and
    non-zero `listing.oracleConfig.assertionPolicyHash`.
- Policy C deadline semantics are enforced at treasury level:
  - goal success assertions can only be registered before treasury deadline,
  - budget success assertions are pre-deadline by default, with a one-time post-deadline registration exception during active reassert grace,
  - once registered, success can finalize after deadline,
  - pending success assertions block terminalization only while unresolved.
- Removed-budget terminalization is preset-specific:
  - open-preset `BudgetTCR` removals unregister the budget from `BudgetStakeLedger` and remove the parent goal-flow recipient,
  - open-preset pre-activation removal disables budget success resolution and strict-finalizes terminal `Failed`,
  - open-preset activation-locked removal enforces spend-stop and preserves normal success/expiry/failure lifecycle progression (no auto-forced failure on removal),
  - managed-preset `ManagedBudgetController` removal detaches the parent recipient, fail-closes through `failRemovedBudget()`, and best-effort syncs the goal treasury inline,
  - exact-byte relists are rejected once a stack has ever been deployed for that `itemID`; only pre-activation removals may be resubmitted because no child-flow recipient was deployed yet.

3. Allocation determinism
- Allocation inputs and witness/commit semantics must remain deterministic and auditable.
- Flow initialization configures exactly one allocation strategy, exposed at runtime via `strategy()`.
- Primary allocation updates use the default-strategy entrypoint (`allocate(...)`) with `allocationKey(msg.sender, "")`.
- Previous committed allocation weight for `(strategy, allocationKey)` is sourced on-chain (`allocWeightPlusOne`).
- Allocation commitments are canonical over recipient ids + allocation scaled only (weight is tracked separately in cache/events).
- Budget stake-ledger checkpoint merges require sorted/unique recipient-id arrays and fail closed on malformed order.
- Budget change detection is ledger-owned:
  - `BudgetStakeLedger.checkpointAllocation(...)` returns changed budget treasuries while applying checkpoints,
  - `BudgetStakeLedger.previewChangedBudgetTreasuries(...)` reuses the same delta ordering semantics for read-only preview,
  - changed-budget ordering remains decreases first, then increases, stable within each bucket.
- Budget stake-ledger checkpointing fails closed on stored-vs-expected allocation drift (no silent reconciliation/clamping).
- `allocationPipeline` is configured at flow initialization and validated fail-fast during init.
- Goal-flow allocation-ledger validation (goal treasury wiring + goal-scoped strategy compatibility, including
  empty-aux `allocationKey(account, "")` round-trip probing) is owned by `GoalFlowAllocationLedgerPipeline` via `GoalFlowLedgerMode`.
- Budget-stack topology is controller-owned and read through `IBudgetController` / `IBudgetStackTopologyReader`:
  - open preset registry: `BudgetTCR`
  - managed preset registry: `ManagedBudgetController`
  - child-sync target resolution discovers topology via `budgetTreasury.authority() -> IBudgetStackTopologyReader`
    and still fail-closes unless the live child flow's configured `strategy()` matches stored topology.
- Pipeline instances with `allocationLedger == 0` are explicit no-op mode and do not checkpoint.
- Goal-flow ledger checkpointing and child-sync enforcement/execution are executed through the configured
  post-commit pipeline (`src/hooks/GoalFlowAllocationLedgerPipeline.sol`) after successful allocation commits.
- Architecture decision update (2026-03-03): downstream child-sync execution remains best-effort per target, but
  allocator state is fail-closed when unresolved child-sync debt exists.
- Implementation note:
  - unresolved targets emit `ChildAllocationSyncSkipped(..., "TARGET_UNAVAILABLE")`,
  - failed child sync calls emit `ChildAllocationSyncAttempted(..., success=false)`,
  - allocation-edit commits open account-level debt on gas-budget skips (`"GAS_BUDGET"`) and failed child sync calls,
  - maintenance-sync commits (`syncAllocation`, `syncAllocationForAccount`, `clearStaleAllocation`) are clear-only:
    successful child sync clears existing debt, but skip/failure outcomes do not open new debt,
  - subsequent composition-changing allocation commits for that account revert with
    `ACCOUNT_HAS_CHILD_SYNC_DEBT` until debt is cleared by successful sync or
    permissionless `repairChildSyncDebt(account, budgetTreasury)`.
- Goal-ledger strategy capability is explicit via `src/interfaces/IGoalScopedAllocationStrategy.sol`;
  `src/interfaces/IGoalLedgerStrategy.sol` remains a legacy alias for that goal-scoped boundary
  (`IAllocationStrategy` + `IAllocationKeyAccountResolver` + `goalTreasury()`).
- Goal allocation pipeline budget-risk hook:
  - open preset: after `BudgetStakeLedger.checkpointAllocation(...)` reports changed budget treasuries, the pipeline checkpoints each
    budget's `PremiumEscrow` for the allocating account,
  - managed preset: the same seam resolves to `NullPremiumEscrow`, preserving topology compatibility without real premium accounting,
  - `previewChildSyncRequirements(...)` derives changed budgets from the ledger preview path instead of reimplementing merge semantics,
  - checkpoint failures still fail closed on allocation commit so the configured premium/risk seam cannot silently diverge from ledger state.

4. Governance boundary clarity
- Recipient-admin/operator/governor permissions should stay explicit with no ambiguous authority paths.
- Flow role boundaries are explicit:
  - `recipientAdmin`: recipient lifecycle (`addRecipient`, `addFlowRecipient`, remove paths, metadata).
  - `flowOperator`/`parent`: flow-rate mutation (`setTargetOutflowRate`, `refreshTargetOutflowRate`).
  - `sweeper`: held SuperToken sweep authority (`sweepSuperToken`).
- Deployment-time flow config knobs are init-only:
  - `flowImpl`, `managerRewardPoolFlowRatePpm`,
    `managerRewardPool`, and `allocationPipeline` are set during initialization.
  - Runtime setter entrypoints for those fields are intentionally removed from the flow surface.
- Child-sync and treasury-sync recovery are permissionless and observable:
  - parent allocation maintenance uses default-strategy `syncAllocation`/`clearStaleAllocation` with pipeline-driven child sync attempts.
  - account-level child-sync debt repair is permissionless via
    `GoalFlowAllocationLedgerPipeline.repairChildSyncDebt(account, budgetTreasury)`.
  - budget treasury maintenance uses controller-owned best-effort batch sync (`BudgetTCR.syncBudgetTreasuries` or `ManagedBudgetController.syncBudgetTreasuries`).
  - per-target failures are emitted and recoverable without queue-based retries.
- `AllocationMechanismTCR` enforces a hard active recipient cap (`MAX_ACTIVE_MECHANISM_RECIPIENTS = 7`):
  - activation reverts when the cap is reached,
  - active count decrements on funding-stop and removal-finalization recipient removals.
- New per-budget `AllocationMechanismTCR` instances initialize with a non-empty initial factory set from
  `BudgetTCRDeployer`; the default stack seeds both `RoundFactory` and `TeamFlowFactory`.
- `TeamFlowFactory` deploys a single `TeamFlow` runtime, returns it as both the mechanism and payout recipient, and
  keeps the existing mechanism-escrow release path unchanged.
- `TeamFlow` is a concrete payout `Flow` runtime with self-owned `recipientAdmin`, `flowOperator`, and `sweeper`
  roles; it assigns fixed per-seat units and hard-removes departed seats via `removeRecipient`.
- Runtime budget recipient add/remove operations are executed directly by the per-goal budget controller, so goal-flow `recipientAdmin` should be configured to that controller (`BudgetTCR` for open goals, `ManagedBudgetController` for managed goals).
- Child flow synchronization is explicit per recipient:
  - `ParentSynced` (default): parent allocation pipeline computes/applies child sync updates.
  - `ManagerSynced`: parent skips auto-sync; child budget treasury/flow operator owns rate updates.
  - `BudgetTCR` marks newly deployed budget child flows as `ManagerSynced`.
- `BudgetTCR` exposes permissionless retry for removed-but-unresolved budget progression (`retryRemovedBudgetResolution`) on the open preset:
  - pre-activation removals retry terminal-only resolution,
  - activation-locked removals retry spend-stop + treasury sync progression.
- `ManagedBudgetController` fail-closes removals on the managed preset:
  - removals use the treasury's controller-only removal terminalization path for both pre-activation and activated budgets,
  - the controller finishes parent detachment plus best-effort goal sync inline, while the treasury skips the redundant inline prune callback for that removal finalization,
  - later `sync()` calls cannot reopen spend after removal.
- Budget controllers expose permissionless best-effort budget treasury batch sync:
- open preset (`BudgetTCR.syncBudgetTreasuries`):
  - skips undeployed/inactive item IDs,
  - continues on per-treasury `sync()` failures and reports per-item outcomes via events.
- managed preset (`ManagedBudgetController.syncBudgetTreasuries`):
  - skips unknown/inactive item IDs,
  - continues on per-treasury `sync()` failures and reports per-item outcomes via events.
- `BudgetStakeLedger.registerBudget(...)` treats goal-flow `recipientAdmin` (the per-goal budget controller implementing `IBudgetStackTopologyReader`) as the canonical budget topology source and keeps a lightweight runtime cross-check against `budgetTreasury.flow()` and child-parent wiring before coverage tracking is admitted.
- Stack deployers remain mechanical helpers:
  - `BudgetTCRDeployer` is `onlyBudgetTCR` and serves the open preset,
  - `ManagedBudgetControllerStackDeployer` is `ONLY_CONTROLLER` and serves the managed preset.
- `BudgetTreasury` is controller-gated (initializer-set one-time controller, no ownership transfer/renounce surface).
- Goal stack slasher wiring is init-only and fail-fast:
  - `GoalFactoryCoreStackDeploy` predeploys juror/underwriter slasher routers and passes them into `GoalTreasury.initialize`,
  - `GoalTreasury.initialize` sets both StakeVault slashers exactly once,
  - `StakeVault` slasher setters are callable only by `goalTreasury` (no treasury-authority callback path).
  - `BudgetTCRFactory` remains the sole `JurorSlasherRouter` authority and authorizes each per-budget allocation-mechanism arbitrator through the authenticated stack-deployer callback path.
  - `RoundFactory` round arbitrators keep stake-vault voting but are intentionally deployed as non-slashing and are never added to the router allowlist.
- Budget child-flow role wiring is preset-specific and explicit:
  - open preset: `BudgetTCR` creates the child recipient using `BudgetTCRDeployer` stack-module config, typically with the budget treasury as `flowOperator` / `sweeper` and the mechanism-layer admin as child `recipientAdmin`,
  - managed preset: `ManagedBudgetController` creates the child recipient with itself as child `recipientAdmin`, the cloned budget treasury as `flowOperator` / `sweeper`, and keeps both child admin and budget-flow allocation authority on the controller contract so Safe authority handoff stays controller-centric.
- Budget stack topology is registry-owned rather than graph-discovered:
  - `BudgetTCR` and `ManagedBudgetController` both expose direct topology getters plus reverse lookups by budget treasury and child flow,
  - inactive/removed stacks remain discoverable through that registry surface with `active == false`.
- `BudgetFlowRouterStrategy` uses contextual flow routing:
  - the open preset registers each newly deployed child flow once (`childFlow -> recipientId`) through the stack deployer,
  - strategy reads canonical `budgetForRecipient(recipientId)` from `BudgetStakeLedger` and fails closed when missing/resolved.
- Stack deployers use clone-first treasury setup:
  - `BudgetTCRDeployer` deploys an uninitialized `BudgetTreasury` clone during `prepareBudgetStack` for the open preset,
  - `ManagedBudgetControllerStackDeployer.prepareBudgetStack(...)` does the same for managed budgets and pairs that clone with a cloned `NullPremiumEscrow` plus a controller-owned/controller-allocated `BudgetSingleAllocatorStrategy`; `budgetAllocationLedger`, `goalFlow`, and goal-treasury-derived runtime context are not prepare-phase inputs and are wired later during `deployBudgetTreasury(...)`,
  - budget treasury initialization still happens after child-flow creation in both stacks.
- `BudgetTCRFactory` uses EIP-1167 clones for BudgetTCR/arbitrator/deployer/validator implementations to keep factory runtime under EIP-170.

## Verification Baseline

- `forge build -q`
- `pnpm -s test:lite`
- `bash scripts/check-agent-docs-drift.sh`
- `bash scripts/doc-gardening.sh --fail-on-issues`

## Static Analysis Triage Assumptions

Medium-severity Slither findings are suppressed only at specific call-sites, not globally:

- `incorrect-equality`:
  - `src/goals/BudgetTreasury.sol` (`deadline == 0`, `remaining == 0`)
  - `src/goals/GoalTreasury.sol` (`remaining == 0`)
  - `src/goals/StakeVault.sol` (`weightDelta == 0`)
  - `src/tcr/GeneralizedTCR.sol` (`remainingRequired == 0`)
  - Assumption: these are integer/discrete state guards (not floating-point style comparisons), so strict equality is intentional and deterministic.

- `locked-ether`:
  - `src/hooks/GoalRevnetSplitHook.sol` (payable split hook entrypoint)
  - `src/hooks/CobuildSplitHook.sol` (payable split hook entrypoint)
  - Assumption: hook rejects native value (`msg.value` must be zero) and only processes configured ERC20/super token flows; it is not used as an ETH custody contract.

- `reentrancy-no-eth`:
  - `src/Flow.sol` (`__Flow_init`, `removeRecipient`, `bulkRemoveRecipients`, `_setFlowRate`)
  - `src/flows/CustomFlow.sol` (`allocate`)
  - `src/tcr/BudgetTCRDeployer.sol` (`prepareBudgetStack`, `deployBudgetTreasury`)
  - Assumption: these paths are protected by access control and/or `nonReentrant`, and external protocol calls are expected integration points where post-call writes are required to preserve flow-sync liveness semantics.

Additional non-medium suppression kept with explicit rationale:

- `arbitrary-send-erc20`:
  - `src/tcr/ERC20VotesArbitrator.sol` (`createDispute`)
  - Assumption: `onlyArbitrable` constrains caller, and transfer source is fixed to the configured `arbitrable` contract by design.

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
- Goal/vault helper libraries: `src/goals/library/*.sol` (treasury flow/donation helpers plus extracted stake/slash math modules).
- Allocation strategies:
  - `src/goals/StakeVault.sol` (goal-flow weighting from live stake-vault weight via built-in strategy surface).
  - `src/allocation-strategies/BudgetFlowRouterStrategy.sol` (shared per-goal budget-flow weighting from per-budget stake checkpoints in `BudgetStakeLedger`, resolved via registered caller-flow context and quantized to Flow unit-weight resolution).
- Budget premium escrow for underwriting accrual/slashing windows: `src/goals/PremiumEscrow.sol`.
- Underwriter slash routing + conversion path: `src/goals/UnderwriterSlasherRouter.sol`.
- Revnet funding ingress hook: `src/hooks/GoalRevnetSplitHook.sol`.
- Shared goal funding terminal: `src/juicebox/CobuildTerminal.sol`.
- Community reserved-token routing layer: `src/hooks/CobuildSplitHook.sol`, `src/juicebox/CobuildPaymentTerminal.sol`, `src/juicebox/CobuildPaymentTerminalFactory.sol`.

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
- Budget credit-line eligibility is enforced in `BudgetTCR.syncBudgetTreasuries` through goal-flow recipient gating:
  - cumulative exposure meter is `goalFlow.getTotalReceivedByMember(childFlow)`,
  - insured line is slashable first-loss principal `budgetTotalAllocatedStake(budgetTreasury) * budgetSlashPpm / 1e6`,
  - optional `runwayCap` remains an additional lower ceiling on cumulative received funding,
  - over-limit recipients are disabled (`setRecipientEnabled(..., false)`) so effective pool units are forced to zero,
  - recipients are re-enabled once exposure is back under line after additional coverage credit,
  - budget `executionDuration` no longer increases insured principal; it only affects downstream treasury pacing/lock time,
  - enforcement runs before per-budget treasury `sync()` in each batch iteration so the same cycle observes the updated gate state,
  - enforcement is best-effort per item; external-call failures emit `BudgetCreditCapEnforcementFailed` and batch sync continues.
- Budget underwriting premium/slash routing is hard-cutover:
  - each budget child flow manager-reward stream is routed to that budget's `PremiumEscrow` at `budgetPremiumPpm`,
  - `PremiumEscrow` premium entitlement uses a balance-index over live `BudgetStakeLedger` coverage checkpoints (no snapshot-only settlement),
  - `PremiumEscrow` goal-flow receipt baseline/checkpoint reads are accounting-critical and fail closed on read failure (no zero-baseline or silent checkpoint-skip fallback),
  - premium claims are gated on goal success (`GoalTreasury.state() == Succeeded`),
  - premium inflow with zero total budget coverage is recycled to goal funding via goal flow (no stranded/orphan premium),
  - on goal `Expired`, `PremiumEscrow.burnOnGoalFailure()` sweeps escrowed premium to goal flow and best-effort triggers `GoalTreasury.settleLateResidual()` burn settlement,
  - on terminal budget failure after activation (`Failed` or post-activation `Expired`), `PremiumEscrow` treats `creditDrawn` as first-loss principal attributed to each underwriter and slashes `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)`, routing through the per-goal underwriter slasher router,
  - slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on budget
    `executionDuration`.
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
  - `CobuildPaymentTerminalFactory` is the canonical deployment path for the community-scoped `CobuildSplitHook`:
    - it deterministically derives the split-hook clone address from caller + goal-registry + shared route-setter + salt,
    - deploys the split hook,
    - initializes `CobuildSplitHook` with the shared `CobuildPaymentTerminal` as its fixed `routeSetter`,
    - completes same-transaction community registration on that terminal via an owner-signed registration payload.
  - `CobuildPaymentTerminal` is a shared community payment terminal:
    - it must be the community revnet's canonical `DIRECTORY` primary terminal for both native ETH and the registered payment token before registration succeeds,
    - each community binds `(splitHook, paymentToken, paymentSourceRevnetId, directNativeAllowed)` exactly once through owner-driven registration,
    - `pay(...).metadata` can still carry `abi.encode(uint256[] goalIds, uint32[] weights)` for one-shot explicit routing,
    - native ETH either records a canonical JB pay directly on that terminal when `directNativeAllowed` is enabled or first buys the configured payment token from `paymentSourceRevnetId`,
    - if the upstream native terminal is this same shared terminal, the conversion path stays internal instead of re-entering through an external `pay(...)` call,
    - direct payment-token pays are likewise recorded on the shared terminal without the intermediate conversion step,
    - community pays are recorded through the JB terminal store so pause/weight/base-currency rules and pay-hook fulfillment stay aligned with standard terminal semantics,
    - after the community pay, the terminal synchronously calls the community controller's `sendReservedTokensToSplitsOf(...)` when that pay created reserved tokens.
  - `CommunityGoalRegistry` is the canonical onchain source of donor-visible goals:
    - community-listed goals go through `GeneralizedTCR` request/challenge/arbitration flow using canonical `bytes32(goalId)` item IDs,
    - owner-backed system goals can be pinned/unpinned directly and carry per-goal `floorPpm` metadata,
    - configured system-goal floor total is capped at `1_000_000` ppm,
    - each listing carries metadata plus paused/selectable state, and system listings additionally expose `floorPpm`.
  - `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury`:
    - `GoalFactory` registers each deployed goal treasury exactly once,
    - owner-authorized future goal-factory versions can register into the same registry over time,
    - treasury identity is immutable per goal id once registered.
  - `CobuildTerminal` is the shared goal funding terminal:
    - it resolves each goal's payment token and source revnet from the registered goal treasury + stake vault at pay time,
    - native ETH pays the resolved source revnet's native terminal to acquire the goal's funding token before forwarding,
    - direct payment-token funding uses the same resolved token and forwards to the goal's primary terminal for that token.
  - `CobuildSplitHook` is controller-gated for the configured community revnet, keeps only a fixed init-time
    contract `routeSetter` plus fixed init-time goal-registry reference and deployment-registry reference, validates
    explicit routes against `CommunityGoalRegistry.isSelectable(goalId)`, peels off configured system-goal floor
    slices first and routes them to canonical goal-treasury beneficiaries, then applies explicit/discretionary routing
    only to the remaining amount, records observed volume only from discretionary explicit routed pays, and routes
    discretionary backlog only through the paginated permissionless backlog-flush path.
  - Canonical-terminal-routed community pays snapshot any preexisting controller backlog before the pay so a user-selected
    route cannot capture earlier backlog.
  - `CobuildSplitHook` only accepts controller callbacks where its split percent is the full reserved-token bucket
    (`JBConstants.SPLITS_TOTAL_PERCENT`); fractional reserved-split configs are invalid because the hook backlog-snapshot
    math assumes one coherent bucket.
  - If the canonical-terminal pay creates reserved tokens, the terminal forces same-transaction split delivery; explicit-route
    pending state must be consumed in that same transaction.
  - If an explicit canonical-terminal pay creates no reserved tokens, the terminal clears the unused pending route instead of
    leaving stale routing state behind.
  - If a configured system goal is paused or otherwise not currently selectable, its floor share falls back into the
    discretionary remainder instead of bricking community routing.
  - Empty-metadata canonical-terminal pays do not seed any pending route. Any reserved tokens created by that pay are flushed into
    hook-managed backlog for later permissionless historical routing.
  - Raw direct community pays and all controller callbacks without a pending explicit route defer the full amount into
    hook-managed backlog instead of routing it inline. Backlog flushes use historical explicit-volume weights and pay
    each child goal terminal with that goal's deployment-registry-provided treasury as beneficiary; backlog flushes do
    not mutate the historical routing signal.
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
- Removed budgets are terminalized via `BudgetTCR` removal flows:
  - removal unregisters the budget from `BudgetStakeLedger` and removes the parent goal-flow recipient,
  - pre-activation removal disables budget success resolution and strict-finalizes terminal `Failed`,
  - activation-locked removal enforces spend-stop and preserves normal success/expiry/failure lifecycle progression (no auto-forced failure on removal),
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
- Goal-flow allocation-ledger validation (goal treasury wiring + strategy compatibility, including
  empty-aux `allocationKey(account, "")` probing) is owned by `GoalFlowAllocationLedgerPipeline` via `GoalFlowLedgerMode`.
- `BudgetTCR` is the canonical budget-stack topology registry:
  - activation records per-item `childFlow`, `budgetTreasury`, `premiumEscrow`, shared child strategy, allocation mechanism,
    and mechanism arbitrator before `BudgetStakeLedger.registerBudget(...)`,
  - child-sync target resolution discovers topology via `budgetTreasury.authority() -> BudgetTCR` and then still
    fail-closes unless the live child flow's configured `strategy()` matches stored topology.
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
- Goal-ledger strategy capability is explicit via `src/interfaces/IGoalLedgerStrategy.sol`
  (`IAllocationStrategy` + `IAllocationKeyAccountResolver` + `IHasStakeVault`).
- Goal allocation pipeline underwriting hook:
  - after `BudgetStakeLedger.checkpointAllocation(...)` reports changed budget treasuries, the pipeline checkpoints each
    budget's `PremiumEscrow` for the allocating account,
  - `previewChildSyncRequirements(...)` derives changed budgets from the ledger preview path instead of reimplementing merge semantics,
  - checkpoint failures fail closed on allocation commit to preserve premium/slash accounting correctness.

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
  - budget treasury maintenance uses `BudgetTCR.syncBudgetTreasuries` best-effort batch sync.
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
- Runtime budget recipient add/remove operations are executed directly by `BudgetTCR`, so goal-flow `recipientAdmin` should be configured to the per-goal `BudgetTCR`.
- Child flow synchronization is explicit per recipient:
  - `ParentSynced` (default): parent allocation pipeline computes/applies child sync updates.
  - `ManagerSynced`: parent skips auto-sync; child budget treasury/flow operator owns rate updates.
  - `BudgetTCR` marks newly deployed budget child flows as `ManagerSynced`.
- `BudgetTCR` exposes permissionless retry for removed-but-unresolved budget progression (`retryRemovedBudgetResolution`):
  - pre-activation removals retry terminal-only resolution,
  - activation-locked removals retry spend-stop + treasury sync progression.
- `BudgetTCR` exposes permissionless best-effort budget treasury batch sync (`syncBudgetTreasuries`):
  - skips undeployed/inactive item IDs,
  - continues on per-treasury `sync()` failures and reports per-item outcomes via events.
- `BudgetStakeLedger.registerBudget(...)` treats goal-flow `recipientAdmin` (`BudgetTCR`) as the canonical budget
  topology source and keeps a lightweight runtime cross-check against `budgetTreasury.flow()` and child-parent wiring
  before coverage tracking is admitted.
- `BudgetTCRDeployer` remains a mechanical helper (`onlyBudgetTCR`) that prepares stack components and deploys budget treasury instances.
- `BudgetTreasury` is controller-gated (initializer-set one-time controller, no ownership transfer/renounce surface).
- Goal stack slasher wiring is init-only and fail-fast:
  - `GoalFactoryCoreStackDeploy` predeploys juror/underwriter slasher routers and passes them into `GoalTreasury.initialize`,
  - `GoalTreasury.initialize` sets both StakeVault slashers exactly once,
  - `StakeVault` slasher setters are callable only by `goalTreasury` (no treasury-authority callback path).
  - `BudgetTCRFactory` remains the sole `JurorSlasherRouter` authority and authorizes each per-budget allocation-mechanism arbitrator through the authenticated stack-deployer callback path.
  - `RoundFactory` round arbitrators keep stake-vault voting but are intentionally deployed as non-slashing and are never added to the router allowlist.
- Budget stack activation no longer deploys a temporary manager contract or performs post-deploy authority handoff:
  - `BudgetTCR` creates the child recipient with explicit child roles (`recipientAdmin`, `flowOperator`, `sweeper`),
  - current budget stack wiring sets those child roles to the cloned budget treasury address during creation.
- Budget stack topology is registry-owned rather than graph-discovered:
  - `BudgetTCR` exposes direct topology getters plus reverse lookups by budget treasury and child flow,
  - inactive/removed stacks remain discoverable through that registry surface with `active == false`.
- `BudgetFlowRouterStrategy` uses contextual flow routing:
  - `BudgetTCR` registers each newly deployed child flow once (`childFlow -> recipientId`) through the stack deployer,
  - strategy reads canonical `budgetForRecipient(recipientId)` from `BudgetStakeLedger` and fails closed when missing/resolved.
- `BudgetTCRDeployer` uses clone-first treasury setup:
  - deploys an uninitialized `BudgetTreasury` clone during `prepareBudgetStack`,
  - anchors `StakeVault.goalTreasury` to that real clone address,
  - initializes the clone during `deployBudgetTreasury` after child-flow creation.
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

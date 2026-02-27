# Cobuild Protocol Architecture

Last updated: 2026-02-27

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
- Concrete implementation: `src/flows/CustomFlow.sol`.
- Core libraries: `src/library/FlowInitialization.sol`, `src/library/FlowAllocations.sol`, `src/library/FlowRates.sol`, `src/library/FlowPools.sol`, `src/library/FlowRecipients.sol`.
- Storage layout boundary: `src/storage/FlowStorage.sol`.
- Child runtime deployment uses EIP-1167 minimal clones (`Clones.clone`) for initializer-based setup and isolated storage per flow instance.
- Flow runtimes are intentionally non-upgradeable and expose no runtime upgrade selector.

### Goal and treasury system

- Shared treasury mechanics base: `src/goals/TreasuryBase.sol`.
- Goal lifecycle treasury: `src/goals/GoalTreasury.sol`.
- Budget lifecycle treasury: `src/goals/BudgetTreasury.sol`.
- Goal stake vault: `src/goals/GoalStakeVault.sol`.
- Goal/escrow/vault helper libraries: `src/goals/library/*.sol` (treasury flow/donation helpers plus extracted stake/rent/reward math modules).
- Allocation strategies:
  - `src/goals/GoalStakeVault.sol` (goal-flow weighting from live stake-vault weight via built-in strategy surface).
  - `src/allocation-strategies/BudgetFlowRouterStrategy.sol` (shared per-goal budget-flow weighting from per-budget stake checkpoints in `BudgetStakeLedger`, resolved via registered caller-flow context and quantized to Flow unit-weight resolution; reward points are computed as window-normalized matured support on the same effective stake basis, with warmup using a fixed global maturation window).
- Reward escrow for finalized goal distribution: `src/goals/RewardEscrow.sol`.
- Revnet funding ingress hook: `src/hooks/GoalRevnetSplitHook.sol`.

### TCR and arbitration system

- TCR core: `src/tcr/GeneralizedTCR.sol`.
- Arbitrator: `src/tcr/ERC20VotesArbitrator.sol` (supports default ERC20Votes mode and optional stake-vault-backed juror mode).
- `GeneralizedTCR` and `ERC20VotesArbitrator` are deployed as direct, non-upgradeable runtime instances.
- Invalid/no-vote arbitrator round rewards route to a configured sink (`invalidRoundRewardSink`).
- Budget curation extension:
  - `src/tcr/BudgetTCR.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/BudgetTCRFactory.sol`
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
  - Goal treasury uses a spend-pattern target model (linear locked today) from treasury balance over remaining time.
    Goal sync proactively caps linear targets with a buffer-derived liquidation-horizon bound when the target is currently
    buffer-affordable, then applies best-effort writes (target, fallback bounded, then zero on persistent write failure).
  - Budget treasury uses pass-through targeting from trusted parent member flow-rate (`parent.getMemberFlowRate(child)`) and applies
    best-effort writes with buffer-aware fallback semantics.
- `GoalRevnetSplitHook` is controller-gated and treasury-state derived:
  - If `goalTreasury.canAcceptHookFunding()`, reserved inflow funds the goal flow.
  - If treasury state is `Succeeded` and minting is still open, reserved inflow uses success-settlement split (reward escrow + burn) with immutable `successSettlementRewardEscrowPpm`.
  - If treasury is terminal and success-settlement mode is closed, reserved inflow is processed through treasury terminal settlement policy.
  - If treasury funding is closed but still nonterminal, reserved inflow is deferred on treasury until terminal settlement is known.
- Budget finalization is state-first: it commits terminal state, then best-effort attempts residual child-flow settlement back to the parent goal flow.
- Goal finalization is state-first: it commits terminal state, then best-effort attempts residual goal-flow settlement:
  - `Succeeded`: split by treasury-configured `successSettlementRewardEscrowPpm` into reward escrow + controller burn.
  - `Expired`: burn 100% via controller.
- Goal and budget terminal side effects are permissionlessly retryable via `retryTerminalSideEffects()`.
- Goal terminal-state residual policy is reusable post-finalize via `settleLateResidual` to process late budget/stream inflows.
- Budget terminal-state residual sweep is reusable post-finalize via `settleLateResidualToParent` to process late child-flow inflows.
- Failed escrow sweeps now apply terminal no-reward policy for both assets:
  - swept goal-token rewards burn via controller,
  - swept cobuild rewards also burn via controller using immutable `cobuildRevnetId` (seeded from `goalRevnetId`).
- Goal success no longer blocks on unresolved tracked budgets for treasury-state progression:
  - treasury success resolution can complete immediately,
  - reward escrow success-finalization is deferred until tracked budgets are resolved and then retried permissionlessly,
  - points accrual snapshots remain anchored to the recorded success timestamp, with per-budget raw accrual clamped by earliest exogenous cutoff (`activatedAt`, `fundingDeadline`, or removal),
  - budget success eligibility is evaluated at reward-finalization using terminal budget outcome (not `resolvedAt <= successAt`).
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
- Removed budgets use activation-locked split semantics:
  - pre-activation removals disable budget success resolution and remain success-ineligible,
  - post-activation removals stop forward spend/funding but preserve reward-history eligibility;
    those budgets remain success-eligible only if they later resolve terminal `Succeeded`.

3. Allocation determinism
- Allocation inputs and witness/commit semantics must remain deterministic and auditable.
- Flow initialization requires exactly one configured allocation strategy.
- Primary allocation updates use the default-strategy entrypoint (`allocate(bytes prevWitness, ...)`) with
  `allocationKey(msg.sender, "")`.
- Previous committed allocation weight for `(strategy, allocationKey)` is sourced on-chain (`allocWeightPlusOne`).
- Allocation commitments are canonical over recipient ids + allocation scaled only (weight is tracked separately in cache/events).
- Budget stake-ledger checkpoint merges require sorted/unique recipient-id arrays and fail closed on malformed order.
- Budget stake-ledger checkpointing fails closed on stored-vs-expected allocation drift (no silent reconciliation/clamping).
- `allocationPipeline` is configured at flow initialization and validated fail-fast during init.
- Goal-flow allocation-ledger validation (goal treasury wiring + strategy compatibility, including
  empty-aux `allocationKey(account, "")` probing) is owned by `GoalFlowAllocationLedgerPipeline` via `GoalFlowLedgerMode`.
- Pipeline instances with `allocationLedger == 0` are explicit no-op mode and do not checkpoint.
- Goal-flow ledger checkpointing and child-sync enforcement/execution are executed through the configured
  post-commit pipeline (`src/hooks/GoalFlowAllocationLedgerPipeline.sol`) after successful allocation commits.
- Architecture decision (2026-02-24): downstream allocation child-sync execution is best-effort and must not brick
  upstream parent `allocate`/`syncAllocation` consumers. Child-target resolution/sync failures must stay observable
  and recoverable via permissionless repair calls (`syncAllocation` / `clearStaleAllocation`) by workers/keepers.
- Implementation note: unresolved targets emit `ChildAllocationSyncSkipped(..., "TARGET_UNAVAILABLE")`; failed child
  sync calls emit `ChildAllocationSyncAttempted(..., success=false)` and parent allocation maintenance paths continue.
- Goal-ledger strategy capability is explicit via `src/interfaces/IGoalLedgerStrategy.sol`
  (`IAllocationStrategy` + `IAllocationKeyAccountResolver` + `IHasStakeVault`).

4. Governance boundary clarity
- Recipient-admin/operator/governor permissions should stay explicit with no ambiguous authority paths.
- Flow role boundaries are explicit:
  - `recipientAdmin`: recipient lifecycle (`addRecipient`, `addFlowRecipient`, remove paths, metadata).
  - `flowOperator`/`parent`: flow-rate mutation (`setTargetOutflowRate`, `refreshTargetOutflowRate`).
  - `sweeper`: held SuperToken sweep authority (`sweepSuperToken`).
- Deployment-time flow config knobs are init-only:
  - `flowImpl`, `managerRewardPoolFlowRatePercent`,
    `managerRewardPool`, and `allocationPipeline` are set during initialization.
  - Runtime setter entrypoints for those fields are intentionally removed from the flow surface.
- Child-sync and treasury-sync recovery are permissionless and observable:
  - parent allocation maintenance uses `syncAllocation`/`clearStaleAllocation` with pipeline-driven child sync attempts.
  - budget treasury maintenance uses `BudgetTCR.syncBudgetTreasuries` best-effort batch sync.
  - per-target failures are emitted and recoverable without queue-based retries.
- Runtime budget recipient add/remove operations are executed directly by `BudgetTCR`, so goal-flow `recipientAdmin` should be configured to the per-goal `BudgetTCR`.
- Child flow synchronization is explicit per recipient:
  - `ParentSynced` (default): parent allocation pipeline computes/applies child sync updates.
  - `ManagerSynced`: parent skips auto-sync; child budget treasury/flow operator owns rate updates.
  - `BudgetTCR` marks newly deployed budget child flows as `ManagerSynced`.
- `BudgetTCR` exposes permissionless retry for removed-but-unresolved budget terminalization (`retryRemovedBudgetResolution`).
- `BudgetTCR` exposes permissionless best-effort budget treasury batch sync (`syncBudgetTreasuries`):
  - skips undeployed/inactive item IDs,
  - continues on per-treasury `sync()` failures and reports per-item outcomes via events.
- `BudgetTCRDeployer` remains a mechanical helper (`onlyBudgetTCR`) that prepares stack components and deploys budget treasury instances.
- `BudgetTreasury` is controller-gated (initializer-set one-time controller, no ownership transfer/renounce surface).
- Treasury-controlled integrations use canonical `ITreasuryAuthority.authority()` directly on configured treasury surfaces:
  - `GoalStakeVault` reads authority through `authority()` on `goalTreasury`,
  - no runtime forwarding resolution or `controller()`/`owner()` probing paths remain.
- Budget stack activation no longer deploys a temporary manager contract or performs post-deploy authority handoff:
  - `BudgetTCR` creates the child recipient with explicit child roles (`recipientAdmin`, `flowOperator`, `sweeper`),
  - current budget stack wiring sets those child roles to the cloned budget treasury address during creation.
- `BudgetFlowRouterStrategy` uses contextual flow routing:
  - `BudgetTCR` registers each newly deployed child flow once (`childFlow -> recipientId`) through the stack deployer,
  - strategy reads canonical `budgetForRecipient(recipientId)` from `BudgetStakeLedger` and fails closed when missing/resolved.
- `BudgetTCRDeployer` uses clone-first treasury setup:
  - deploys an uninitialized `BudgetTreasury` clone during `prepareBudgetStack`,
  - anchors `GoalStakeVault.goalTreasury` to that real clone address,
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
  - `src/goals/GoalStakeVault.sol` (`weightDelta == 0`)
  - `src/tcr/GeneralizedTCR.sol` (`remainingRequired == 0`)
  - Assumption: these are integer/discrete state guards (not floating-point style comparisons), so strict equality is intentional and deterministic.

- `locked-ether`:
  - `src/hooks/GoalRevnetSplitHook.sol` (payable split hook entrypoint)
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

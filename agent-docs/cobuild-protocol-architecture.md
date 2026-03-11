# Cobuild Protocol Detailed Architecture

Last updated: 2026-03-10

## Purpose

Durable architecture reference for module boundaries, integration paths, and protocol invariants.

## Top-Level Domains

### Flow distribution domain

- Core engine: `src/Flow.sol`
- Concrete runtimes: `src/flows/CustomFlow.sol`, `src/teamflow/TeamFlow.sol`
- Shared flow libraries:
  - `src/library/FlowInitialization.sol`
  - `src/library/FlowAllocations.sol`
  - `src/library/FlowRates.sol`
  - `src/library/FlowPools.sol`
  - `src/library/FlowRecipients.sol`
  - `src/library/CustomFlowLibrary.sol`
- Allocation strategies:
  - `src/goals/StakeVault.sol` (implements goal strategy surface directly)
  - `src/allocation-strategies/BudgetFlowRouterStrategy.sol` (shared per-goal budget-flow strategy)
- Child flow runtimes are deployed via EIP-1167 minimal clones (`Clones.clone`) for initializer-based setup and isolated storage.
- Flow runtimes are intentionally non-upgradeable and expose no runtime upgrade selector.
- Allocation strategy modules are direct runtime instances (no proxy/UUPS upgrade path).

### Goal and treasury domain

- Shared treasury mechanics base: `src/goals/TreasuryBase.sol`
- Goal lifecycle treasury: `src/goals/GoalTreasury.sol`
- Canonical deployed-goal registry: `src/goals/GoalDeploymentRegistry.sol`
- Budget lifecycle treasury: `src/goals/BudgetTreasury.sol`
- Optional treasury spend-policy modules: `src/goals/policies/*.sol`
- Stake and weight accounting: `src/goals/StakeVault.sol`
- Underwriting premium/slash modules: `src/goals/PremiumEscrow.sol`, `src/goals/UnderwriterSlasherRouter.sol`
- Goal-domain helper libraries: `src/goals/library/*.sol` (treasury sync/donations plus extracted stake/slash math modules)
- Revnet split ingress: `src/hooks/GoalRevnetSplitHook.sol`
- Community reserved-token routing: `src/hooks/CobuildSplitHook.sol`, `src/juicebox/CobuildCommunityTerminal.sol`, `src/juicebox/CobuildCommunityTerminalFactory.sol`

### Curation and arbitration domain

- TCR core: `src/tcr/GeneralizedTCR.sol`
- ERC20Votes arbitrator: `src/tcr/ERC20VotesArbitrator.sol`
  - Arbitration cost/reward token remains ERC20.
  - Voting power can run in token-votes mode or optional `StakeVault` juror snapshot mode.
- Budget TCR extension:
  - `src/tcr/BudgetTCR.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/BudgetTCRFactory.sol`
  - `src/tcr/AllocationMechanismTCR.sol` (active mechanism registry with hard max of 7 active recipients)
  - `src/teamflow/TeamFlow.sol`, `src/teamflow/TeamFlowFactory.sol` (equal-split team mechanism family)
- Community goal curation:
  - `src/tcr/CommunityGoalRegistry.sol`
- Budget listing validation helpers:
  - `src/tcr/library/BudgetTCRValidationLib.sol`
- Supporting modules:
  - `src/tcr/storage/*.sol`
  - `src/tcr/library/TCRRounds.sol`
  - `src/tcr/utils/*.sol`
  - `src/tcr/strategies/*.sol`

## Key Interaction Paths

1. Flow initialization and allocation
- Concrete flow runtimes initialize through their own entrypoints (`CustomFlow.initialize`, `TeamFlow.initialize`) -> `Flow.__Flow_initWithRoles` -> `FlowInitialization` checks.
- Flow initialization requires exactly one configured allocation strategy.
- `CustomFlow.allocate(bytes32[] ids, uint32[] scaled)` is the primary entrypoint and derives the allocation key from
  caller + empty aux data on the configured strategy.
- Allocation updates are applied through `FlowAllocations` using commitment/previous-state snapshot validation for the resolved
  `(strategy, allocationKey)`.
- Previous committed allocation weight is sourced on-chain per `(strategy, allocationKey)` via `allocWeightPlusOne`.
- Allocation commitments are canonical over recipient ids + allocation scaled only.

2. Flow rate and child synchronization
- Flow-rate updates use `FlowRates` and `FlowPools` helpers.
- Parent-driven child flow-rate queueing is removed from `Flow`; child recipients track allocation units while child `flowOperator` roles (typically budget treasuries) own target-rate mutation.
- Goal-ledger child allocation sync executes through `GoalFlowAllocationLedgerPipeline` with best-effort per-target semantics and explicit observability events.
- `BudgetTCR` is the canonical budget-stack topology registry for that child-sync path:
  - target resolution discovers `childFlow` + child strategy through `budgetTreasury.authority() -> BudgetTCR`,
  - runtime child sync still fail-closes unless the live child flow's configured `strategy()` matches stored topology.
- Gas-budget skips and failed child sync attempts open per-account child-sync debt in the pipeline.
- While child-sync debt exists, checkpoint-requiring allocations for that account fail closed until repaired or cleared.
- Child-sync debt repair is permissionless per budget via `GoalFlowAllocationLedgerPipeline.repairChildSyncDebt(account, budgetTreasury)`.
- Init-only flow deployment knobs:
  - `flowImpl` and `managerRewardPoolFlowRatePpm` are configured
    only at initialization time.
  - Corresponding runtime setter entrypoints are removed from the flow surface.
- `BudgetTCR` also provides permissionless best-effort budget treasury batch sync (`syncBudgetTreasuries`) for keeper-style liveness:
  - skips undeployed/inactive items,
  - continues when individual treasury `sync()` calls fail.
- Flow rate mutators are role-gated:
  - `setTargetOutflowRate` and `refreshTargetOutflowRate`: flow-operator/parent.
- `TeamFlow` is itself the payout flow runtime:
  - the activated mechanism and payout recipient are the same deployed `TeamFlow`,
  - `recipientAdmin`, `flowOperator`, and `sweeper` are all self-owned by that deployed `TeamFlow`,
  - seat changes hard-remove departed recipients and assign fixed per-seat units directly on the flow runtime.

Community root routing
- Canonical deployment of the community split hook is `CobuildCommunityTerminalFactory.deployFor(...)`:
  - the factory deterministically derives the split-hook clone address from caller + goal registry + shared route setter + salt,
  - deploys the split hook,
  - initializes the hook with the shared `CobuildCommunityTerminal` as its fixed `routeSetter`,
  - registers the community on that same terminal in the same transaction via an owner-signed registration payload.
- Community payments can arrive through the shared `CobuildCommunityTerminal` only after the community binds immutable
  routing config and points both its native ETH terminal and registered payment-token terminal at that shared terminal.
- The shared canonical terminal accepts native ETH or the registered community payment token:
  - if `directNativeAllowed`, native ETH is recorded directly on the community revnet through the shared terminal's JB terminal-store path,
  - otherwise native ETH is first paid into the configured `paymentSourceRevnetId` native terminal to acquire the registered payment token,
  - if that upstream native terminal is the same shared terminal, the conversion path stays internal and self-source-safe,
  - direct payment-token pays use that same terminal-store recording path without the intermediate conversion step,
  - the shared terminal fulfills normal JB payment accounting and pay-hook semantics before it flushes reserved tokens into splits.
- The shared terminal optionally decodes route metadata as `abi.encode(uint256[] goalIds, uint32[] weights)`:
  - explicit metadata seeds a one-shot explicit route on `CobuildSplitHook`,
  - empty metadata means "no explicit route", so any reserved tokens created by the pay are flushed into hook-managed backlog.
- Before seeding a new route, the shared terminal snapshots the community controller's current pending reserved-token balance so
  older backlog can be separated from the current pay's newly created reserved-token delta.
- After the community pay returns, if it created reserved tokens, the shared terminal immediately calls
  `sendReservedTokensToSplitsOf(...)` on the community controller so goal routing completes in the same transaction.
- If the community pay created no reserved tokens, the shared terminal clears the unused pending route instead of leaving stale
  state behind.
- Direct goal funding uses the shared `CobuildGoalTerminal`, which resolves each goal's payment token and source revnet
  from the registered goal treasury + stake vault before converting native ETH or forwarding direct payment-token pays.
- `CommunityGoalRegistry` is the canonical onchain source of donor-visible community goals:
  - community-listed goals use standard `GeneralizedTCR` request/challenge/arbitration flow,
  - canonical item identity is `bytes32(goalId)`,
  - the registry is ownerless and does not expose privileged system goals or pause controls,
  - every listed goal carries metadata only; selectability is derived from canonical deployment, funding context, and terminal presence.
- `GoalDeploymentRegistry` is the canonical onchain source of `goalId -> goalTreasury`:
  - `GoalFactory` registers each deployed goal treasury exactly once,
  - future owner-authorized goal-factory versions can register into the same registry,
  - treasury identity is immutable per goal id.
- `CobuildSplitHook` stores a fixed init-time contract `routeSetter`, a fixed init-time `CommunityGoalRegistry` reference for
  explicit-route validation, and a fixed init-time `GoalDeploymentRegistry` reference for direct-pay treasury resolution.
- During canonical-terminal-routed community pays, reserved-token split delivery is forced synchronously by the terminal through the
  community controller's `sendReservedTokensToSplitsOf(...)` call.
- `CobuildSplitHook` forwards the full canonical-terminal pending-route delta into registry-selectable child goals by paying
  each goal's primary terminal for the community token.
- Older controller backlog encountered during a canonical-terminal-routed pay is moved into hook-managed historical backlog for
  later permissionless routing.
- `flushHistoricalBacklog(maxGoalCount)` routes that historical backlog in bounded chunks, so a single backlog retry no
  longer has to scan/pay every historically weighted goal in one transaction.
- All explicit routed payments record observed per-goal volume.
- Historical backlog routing is derived only from selectable goals with non-zero observed explicit volume and is
  only executed through the paginated permissionless backlog-flush path.
- If no pending route exists, the hook defers the full controller callback amount into hook-managed backlog instead of
  routing it inline through the current transaction.
- If no usable historical route exists, the hook keeps historical backlog escrowed on-hook for later permissionless
  retry instead of blocking canonical-terminal-routed mints.

3. Goal treasury funding and resolution
- Revnet ingress arrives through `GoalRevnetSplitHook.processSplitWith`.
- `GoalTreasury.recordHookFunding` and `sync`/`activate` govern transitions.
- Goal treasury supports direct donation ingress while funding is open:
  - `donateUnderlyingAndUpgrade(amount)` (auto-upgrade then transfer),
  - donation receipts are included in `totalRaised` (telemetry).
- Goal treasury min-raise lifecycle gating is balance-based (`superToken.balanceOf(flow)`), not `totalRaised`, so direct flow inflows can satisfy activation.
- Goal treasury target computation is policy-only.
- The current uncapped goal default is `LinearSpendPolicy(includeIncomingRate=false, maxTargetFlowRate=0, syncMode=LinearSpendDownFallback)`, so raw target remains treasury balance over remaining time.
- When the configured policy selects `LinearSpendDownFallback`, goal sync adds a proactive buffer-derived liquidation-horizon cap when the linear target is currently buffer-affordable.
- Goal sync does not enforce coverage-based rate clamping; underwriting is enforced by budget recipient credit-line gating in `BudgetTCR.syncBudgetTreasuries`.
- Goal sync still fail-safe guards empty distribution: when total distribution units are zero, target rate is zero.
- Budget credit-line gating uses:
  - exposure meter: `goalFlow.getTotalReceivedByMember(childFlow)`,
  - insured line: `budgetTotalAllocatedStake(budgetTreasury) * budgetSlashPpm / 1e6`,
  - recipient gating: `goalFlow.setRecipientEnabled(itemID, enabled)` to force units to zero while over line and restore virtual units on re-enable,
  - `runwayCap` acts as an additional lower ceiling when configured,
  - budget `executionDuration` does not increase insured principal; it only affects downstream treasury pacing / lock time,
  - per-item enforcement runs before budget treasury `sync()` in `syncBudgetTreasuries`,
  - best-effort enforcement: failures emit `BudgetCreditCapEnforcementFailed` and do not block the batch.
- Budget treasury active target flow-rate is policy-only.
- The repo-wide default budget deployment is `LinearSpendPolicy(includeIncomingRate=true, maxTargetFlowRate=0, syncMode=Capped)`.
- That preserves current budget targeting:
  - trusted incoming from parent member flow (`max(parent.getMemberFlowRate(child), 0)`),
  - linear balance spenddown (`treasuryBalance / timeRemaining`),
  - total target saturated at `int96.max`.
- Goal and budget treasuries share thin mechanics via `TreasuryBase` (donation ingress wrappers, treasury-balance reads, and flow-zero helper), while retaining separate lifecycle/economic policy logic.
- Finalization path still triggers flow stop + residual settlement + stake-vault resolution.
- Underwriting premium/slash routing is hard-cutover:
  - each budget child flow manager-reward stream is routed to that budget `PremiumEscrow` at `budgetPremiumPpm`,
  - `PremiumEscrow` indexes premium against live budget coverage from `BudgetStakeLedger`,
  - `PremiumEscrow` goal-flow receipt baseline/checkpoint reads are accounting-critical and fail closed on read failure rather than resetting/skipping receipt accounting,
  - premium claims are gated on goal success (`GoalTreasury.state() == Succeeded`),
  - premium inflow with zero total coverage is recycled to goal funding via goal flow,
  - on goal `Expired`, `PremiumEscrow.burnOnGoalFailure()` sweeps escrowed premium to goal flow and best-effort triggers `GoalTreasury.settleLateResidual()` burn settlement,
  - on terminal budget failure after activation (`Failed` or post-activation `Expired`), `PremiumEscrow` treats `creditDrawn` as first-loss principal attributed to each underwriter, caps by strict slash-percent principal (`peakCov * budgetSlashPpm / 1e6`), and routes slashing through `UnderwriterSlasherRouter`.
- `BudgetTCRFactory` treats submission-deposit capability probing as trusted deployment wiring:
  - a clean `supportsEscrowBonding() == false` response preserves manual registry deposits,
  - missing/reverting capability probes now fail deployment fast instead of silently falling back.
- Underwriter slash recycling path:
  - `UnderwriterSlasherRouter` is configured as `StakeVault` underwriter slasher and receives slashed goal/cobuild tokens,
  - router best-effort converts cobuild -> goal token via goal revnet terminal (failures are observable and retained),
  - router upgrades goal token to goal SuperToken and forwards to goal funding target.
- Residual settlement behavior:
  - `Succeeded`: settle goal-flow SuperToken balance and burn 100% via controller.
  - `Failed`/`Expired`: settle and burn 100% via controller.
- Post-finalization late inflows can be settled by calling `GoalTreasury.settleLateResidual()` to apply the same state-dependent residual policy.
- Permissionless `sync()` is the default lifecycle progression path:
  - `Funding`: activate when threshold is met; otherwise expire once funding/deadline windows elapse.
  - `Active`: sync flow-rate while time remains; at/after deadline:
    - goal treasury resolves pending assertions deterministically (`Succeeded` when truthful, `Expired` when false/invalid, else remain active with zero target flow),
    - budget treasury opens a one-time post-deadline reassert grace when the first pending assertion settles false/invalid; it expires once grace elapses without a new pending assertion (or when the grace reassert also settles false/invalid).
  - Terminal states: no-op.
- Manual failure is budget-only and authority-gated:
  - budget treasury `resolveFailure` remains controller-only and deadline-gated (`Funding` after `fundingDeadline`, `Active` at/after `deadline`).
  - goal treasury exposes no manual `resolveFailure` path.
- Success resolution is assertion-backed:
  - immutable `successResolver` role (per treasury) controls `registerSuccessAssertion`/`clearSuccessAssertion`,
  - goal `resolveSuccess` is success-resolver-only and requires a pending truthful assertion id,
  - budget `resolveSuccess` is success-resolver-only and requires a pending truthful assertion id,
  - pending assertions block terminalization races only while unresolved.
- Policy C is implemented at treasury level:
  - goal assertion registration is only allowed before deadline,
  - budget assertion registration is pre-deadline by default with a one-time post-deadline reassert grace exception,
  - success can finalize after deadline when assertion was initiated pre-deadline, or for budgets via the one-time post-deadline grace reassert.
- `GoalRevnetSplitHook` is controller-gated and derives behavior from treasury state:
  - Funding path while `canAcceptHookFunding`.
  - Success-settlement path while treasury state is `Succeeded` and minting remains open (burn path).
  - Closed nonterminal path defers split funds on treasury.
  - Terminal closed path applies treasury terminal settlement policy.
- `CobuildSplitHook` is controller-gated and terminal-seeded:
  - explicit routed pays are seeded by `CobuildCommunityTerminal` through a one-shot pending route and are the only flows
    that update observed historical volume,
  - terminal seeding authority is a fixed init-time `routeSetter` with no runtime rotation surface,
  - empty-metadata canonical-terminal pays do not seed any pending route and instead flush any newly created reserved tokens into
    hook-managed backlog,
  - canonical-terminal-routed pays snapshot and defer preexisting controller backlog so the selected route stays scoped to the
    current payer's new reserved-token delta,
  - goal membership is sourced from fixed init-time `CommunityGoalRegistry` state while treasury beneficiaries are
    sourced from fixed init-time `GoalDeploymentRegistry` state,
  - permissionless backlog flushes use canonical goal treasury beneficiaries rather than a global default beneficiary,
  - missing historical data fails open by keeping backlog escrowed on-hook rather than guessing downstream funding destinations.

4. Budget treasury lifecycle
- Budget treasury uses live treasury balance (`superToken.balanceOf(flow)`) for activation/expiry checks.
- Budget treasury supports direct donation ingress while funding is open:
  - `donateUnderlyingAndUpgrade(amount)`.
- Activation threshold and execution-duration semantics govern outflow windows.
- Active target flow-rate is policy-only; the default budget stack wiring uses `LinearSpendPolicy(includeIncomingRate=true, maxTargetFlowRate=0, syncMode=Capped)`, which preserves the current `incoming + balance / timeRemaining` pacing.
- Budget terminal resolution settles residual child-flow SuperToken balance back to the parent goal flow.
- Post-finalization late child-flow inflows can be settled with `BudgetTreasury.settleLateResidualToParent()`.

5. Stake and underwriting path
- `StakeVault` tracks dual-asset stake and allocation weight.
- Goal-token stake weight in `StakeVault` is snapshot-based:
  - snapshot goal ruleset weight once at vault init and always apply issuance-price weighting (`goalAmount * weightScale / snappedWeight`),
  - snapshot reserved percent once at vault init and apply only as a reserve premium,
  - reserve premium is full pre-activation/at-activation, then decays linearly to zero by deadline,
  - deadline endpoint equals issuance-priced base weight (not raw goal token amount),
  - cobuild stake remains 1:1 weight with amount.
- Goal/cobuild deposits still require live staking-open status (`goalRulesets.currentOf(goalRevnetId).weight > 0`) at call time.
- `StakeVault` maps caller identity to live vault weight for goal-flow allocation via built-in strategy methods.
- `BudgetFlowRouterStrategy` maps caller identity to per-budget stake tracked in `BudgetStakeLedger` using caller-flow context (`msg.sender` child flow -> registered recipient id); checkpointed stake is quantized to Flow unit-weight resolution so sub-unit dust is ignored.
- `BudgetStakeLedger` is coverage-only accounting for per-budget allocated stake plus checkpoint history (no points/rent-time accrual subsystem).
- `PremiumEscrow` checkpoints account coverage, accrues premium from indexed inflows, recycles orphan premium when coverage is zero, and gates claims on parent goal success.
- On goal `Expired`, escrowed premium becomes unclaimable and can be swept to goal flow via `burnOnGoalFailure()` for terminal residual burn settlement.
- `PremiumEscrow.close` freezes coverage at budget terminalization; `PremiumEscrow.slash` treats `creditDrawn` as first-loss principal attributed to the underwriter, caps by strict slash-percent principal (`peakCov * budgetSlashPpm / 1e6`), and dispatches to `UnderwriterSlasherRouter`.
- Slash uses `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)` and does not depend on budget
  `executionDuration`.
- Underwriter withdrawals are caller-prepared post-resolution:
  - `StakeVault.prepareUnderwriterWithdrawal(maxBudgets)` iterates append-only registered budgets and executes required slash settlement for the caller.
  - `withdrawGoal`/`withdrawCobuild` are no longer globally blocked by unrelated unresolved budgets; only caller-specific unresolved exposure prevents that caller from withdrawing.

6. TCR request/challenge/dispute lifecycle
- Item add/remove -> challenge window -> dispute creation in arbitrator.
- Arbitrator ruling feeds back into TCR status resolution and reward accounting.
- In stake-vault mode, delegated commit (`commitVoteFor`) and permissionless per-voter slashing (`slashVoter`) are enabled.
- Slash settlement is sourced from the juror's live stake balances (not only currently locked juror balances), then routed to the arbitrator-selected recipient path.

7. Budget TCR stack lifecycle
- Accepted Budget TCR items deploy stake-vault + child flow + budget treasury stack and reuse one shared per-goal budget router strategy.
- Budget stack activation no longer deploys a per-budget temporary manager contract or does post-deploy authority handoff:
  - `BudgetTCR` creates the child-flow recipient with explicit child roles (`recipientAdmin`, `flowOperator`, `sweeper`),
  - current stack wiring sets those roles to the cloned budget treasury address during creation.
- Budget stack topology is recorded canonically in `BudgetTCR` during activation:
  - stored topology includes `childFlow`, `budgetTreasury`, `premiumEscrow`, shared child strategy, allocation mechanism,
    and allocation-mechanism arbitrator,
  - `BudgetStakeLedger.registerBudget(...)` reads that topology from goal-flow `recipientAdmin` (`BudgetTCR`) and keeps
    a lightweight runtime cross-check against `budgetTreasury.flow()` plus child-parent wiring before tracking coverage.
- Exact-byte relists are fail-fast rejected after any stack deployment for that `itemID`:
  - `Flow` recipient ids are single-use after removal, so deployed listings cannot safely reactivate the same item hash,
  - same-byte resubmission remains allowed only after pre-activation removal because no child-flow recipient was created.
- `BudgetFlowRouterStrategy` uses contextual flow routing:
  - `BudgetTCR` registers each newly deployed child flow once (`childFlow -> recipientId`) through the stack deployer,
  - strategy resolves effective budget address via `BudgetStakeLedger.budgetForRecipient(recipientId)` and fails closed when missing/resolved.
- `BudgetTCRDeployer` uses clone-first treasury setup:
  - it deploys an uninitialized treasury clone during `prepareBudgetStack`,
  - `StakeVault.goalTreasury` is anchored to that real clone address,
  - treasury initialization happens in `deployBudgetTreasury` after child-flow creation.
- `BudgetTCR` now performs runtime parent-flow recipient add/remove operations directly.
- On accepted delisting (on-chain remove/finalize-removed path), budget child outflow is force-zeroed immediately and parent-flow funding is detached during finalization.
- On accepted delisting, `BudgetTCR` disables budget success resolution only for non-locked/pre-activation budgets; those budgets strict-finalize to terminal `Failed`.
- Activation-locked delistings preserve reward-history/success-eligibility and do not auto-force `Failed`; `retryRemovedBudgetResolution(...)` enforces spend-stop and attempts treasury `sync()` progression.
- `BudgetTCRDeployer` remains `onlyBudgetTCR` and mechanical (`prepareBudgetStack` + `deployBudgetTreasury`).
- `BudgetTreasury` is controller-gated (initializer-set one-time controller, no ownership transfer/renounce surface).
- Goal slasher wiring is initialization-bound:
  - `GoalFactoryCoreStackDeploy` predeploys juror/underwriter slasher routers and passes them through `GoalTreasury.GoalConfig`,
  - `GoalTreasury.initialize` configures StakeVault slashers immediately and exactly once,
  - `StakeVault` slasher setters are `goalTreasury`-only (no `goalTreasury.authority()` callback path).
  - `BudgetTCRFactory` remains the sole `JurorSlasherRouter` authority and authorizes each allocation-mechanism arbitrator through the authenticated stack-deployer callback path.
  - `RoundFactory` round arbitrators reuse stake-vault voting power but are intentionally non-slashing and never receive router authorization.
- For add/remove recipient calls, the goal flow `recipientAdmin` should be set to the per-goal `BudgetTCR`.
- `BudgetTCRFactory` consumes a caller-provided `IVotes` token and clones pre-deployed `BudgetTCR`, `ERC20VotesArbitrator`, and `BudgetTCRDeployer` implementations.
- `BudgetTCRFactory.deployBudgetTCRStackForGoal` is restricted to one configured caller (the deployment `GoalFactory`), removing permissionless external access.
- Budget stack discovery for indexers is available from fixed emitters:
  - `BudgetTCRFactory.BudgetTCRStackDeployedForGoal` emits first-hop `BudgetTCR` + arbitrator deployment.
- `BudgetTCRFactory` also re-emits child-stack and mechanism deployment callbacks from registered stack deployers (`BudgetStackDeployed`, `BudgetAllocationMechanismDeployed`) so indexers can discover dynamic children without subscribing to unknown `BudgetTCR` emitters first.
  - The mechanism callback also authorizes the deployed allocation-mechanism arbitrator in the per-goal `JurorSlasherRouter`, so activation fails closed if router wiring is missing or invalid.
  - Round deployments emitted by `RoundFactory` do not trigger juror-router authorization because round arbitrators are non-slashing by design.
- New budget activations seed each per-budget `AllocationMechanismTCR` with both `RoundFactory` and
  `TeamFlowFactory`, so TeamFlow is available immediately as a curated mechanism type without auto-creating a
  mechanism instance.
- Invalid/no-vote arbitrator round rewards are routed to a configured `invalidRoundRewardSink`.

## Test Harness Boundaries

- `test/goals/helpers/RevnetTestHarness.sol` uses a local ruleset simulator (`RevnetTestRulesets`) for 0.8.34 compatibility.
- This harness is not a canonical Nana/JBX implementation; parity/spec-lock tests in `test/goals/GoalRevnetIntegration.t.sol` define and protect the relied-upon behavior.

## Architecture Invariants

1. Allocation determinism
- Allocation updates are commitment-validated and should remain deterministic and auditable.
- Previous committed allocation weight is sourced on-chain from `allocWeightPlusOne`.
- `BudgetStakeLedger.checkpointAllocation` enforces sorted/unique recipient-id ordering to keep linear merge checkpoints sound.
- Budget delta detection is ledger-owned:
  - `BudgetStakeLedger.checkpointAllocation(...)` returns changed budget treasuries on the write path,
  - `BudgetStakeLedger.previewChangedBudgetTreasuries(...)` reuses the same decreases-first ordering for read-only preview,
  - malformed ordering is rejected locally by the ledger merge path rather than by caller convention alone.
- `BudgetStakeLedger.checkpointAllocation` fails closed on stored-vs-expected allocation drift (no silent reconciliation/clamping).
- `allocationPipeline` is configured at flow initialization and validated fail-fast during init.
- Goal-flow allocation-ledger mode validation is enforced by `GoalFlowAllocationLedgerPipeline` via `GoalFlowLedgerMode`,
  including strategy compatibility checks (such as empty-aux `allocationKey(account, "")` probing).
- Pipeline instances with `allocationLedger == 0` are explicit no-op mode and do not checkpoint.
- Goal-flow ledger checkpoint writes and child-sync enforcement/execution are delegated to the configured post-commit
  pipeline (`src/hooks/GoalFlowAllocationLedgerPipeline.sol`) after allocation commit success.
- Architecture decision update (2026-03-03): allocation child-sync execution remains best-effort per target, but
  unresolved child-sync debt fail-closes future checkpoint-requiring allocation commits for that account.
- Implementation note:
  - unresolved targets emit `ChildAllocationSyncSkipped(..., "TARGET_UNAVAILABLE")`,
  - failed child sync calls emit `ChildAllocationSyncAttempted(..., success=false)`,
  - allocation-edit commits open debt with `ChildSyncDebtOpened` on gas-budget skips (`"GAS_BUDGET"`) and failed child sync attempts,
  - maintenance-sync commits (`syncAllocation`, `syncAllocationForAccount`, `clearStaleAllocation`) are default-strategy clear-only:
    successful sync attempts clear existing debt while skip/failure outcomes do not open debt,
  - successful child sync and permissionless per-budget repair clear debt with `ChildSyncDebtCleared`.
- Goal-ledger compatible strategy capability is explicitly represented by
  `src/interfaces/IGoalLedgerStrategy.sol` (`IAllocationStrategy` + `IAllocationKeyAccountResolver` + `IHasStakeVault`).

2. Lifecycle monotonicity
- Goal/Budget/TCR state transitions should be explicit and non-ambiguous.

3. Access control clarity
- Recipient-admin/operator/governor/authorized-caller boundaries must stay explicit.
- Budget stack helper deploy calls are restricted by `BudgetTCRDeployer.onlyBudgetTCR`, while goal-flow `recipientAdmin` authority for budget recipient lifecycle is intentionally held by `BudgetTCR`.

4. Funds safety
- Hook, treasury, flow, vault, and escrow transfer paths must preserve accounting invariants.

5. Upgrade safety
- Flow runtime instances are non-upgradeable at runtime with no upgrade selector, and child instances use EIP-1167 minimal clones.
- Flow storage domains use ERC-7201 namespaced roots (`cfg`, `recipients`, `alloc`, `rates`, `pipeline`, child-flow sets) to avoid cross-domain slot-shift coupling.
- Remaining upgradeable modules must maintain storage compatibility and explicit upgrade auth.
- `BudgetTCR` and `ERC20VotesArbitrator` deployments are direct (non-proxy) instances, so runtime upgrade auth is not part of TCR/arbitrator trust assumptions.

## Test Surface Map

- Flow: `test/flows/*.t.sol`
- Goals/treasury/stake/premium: `test/goals/*.t.sol`
- TCR/arbitrator: `test/GeneralizedTCR*.t.sol`, `test/ERC20VotesArbitrator*.t.sol`, `test/TCRRounds.t.sol`, `test/SubmissionDepositStrategies.t.sol`, `test/BudgetTCR.t.sol`
- Invariants: `test/invariant/*.t.sol`
- Upgrades/harness/mocks: `test/upgrades/*.sol`, `test/harness/*.sol`, `test/mocks/*.sol`

## Verification Defaults

- `forge build -q`
- `pnpm -s test:lite`
- `pnpm -s test:coverage:ci` for CI coverage gates
- `pnpm -s slither` for local static analysis (if installed)

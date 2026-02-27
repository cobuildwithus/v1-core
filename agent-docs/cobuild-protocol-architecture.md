# Cobuild Protocol Detailed Architecture

Last updated: 2026-02-27

## Purpose

Durable architecture reference for module boundaries, integration paths, and protocol invariants.

## Top-Level Domains

### Flow distribution domain

- Core engine: `src/Flow.sol`
- Concrete implementation: `src/flows/CustomFlow.sol`
- Shared flow libraries:
  - `src/library/FlowInitialization.sol`
  - `src/library/FlowAllocations.sol`
  - `src/library/FlowRates.sol`
  - `src/library/FlowPools.sol`
  - `src/library/FlowRecipients.sol`
  - `src/library/CustomFlowLibrary.sol`
- Allocation strategies:
  - `src/goals/GoalStakeVault.sol` (implements goal strategy surface directly)
  - `src/allocation-strategies/BudgetFlowRouterStrategy.sol` (shared per-goal budget-flow strategy)
- Child flow runtimes are deployed via EIP-1167 minimal clones (`Clones.clone`) for initializer-based setup and isolated storage.
- Flow runtimes are intentionally non-upgradeable and expose no runtime upgrade selector.
- Allocation strategy modules are direct runtime instances (no proxy/UUPS upgrade path).

### Goal and treasury domain

- Shared treasury mechanics base: `src/goals/TreasuryBase.sol`
- Goal lifecycle treasury: `src/goals/GoalTreasury.sol`
- Budget lifecycle treasury: `src/goals/BudgetTreasury.sol`
- Stake and weight accounting: `src/goals/GoalStakeVault.sol`
- Reward distribution escrow: `src/goals/RewardEscrow.sol`
- Goal-domain helper libraries: `src/goals/library/*.sol` (treasury sync/donations plus extracted stake/rent/reward math modules)
- Revnet split ingress: `src/hooks/GoalRevnetSplitHook.sol`

### Curation and arbitration domain

- TCR core: `src/tcr/GeneralizedTCR.sol`
- ERC20Votes arbitrator: `src/tcr/ERC20VotesArbitrator.sol`
  - Arbitration cost/reward token remains ERC20.
  - Voting power can run in token-votes mode or optional `GoalStakeVault` juror snapshot mode.
- Budget TCR extension:
  - `src/tcr/BudgetTCR.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/BudgetTCRFactory.sol`
- Budget listing validation helpers:
  - `src/tcr/library/BudgetTCRValidationLib.sol`
- Supporting modules:
  - `src/tcr/storage/*.sol`
  - `src/tcr/library/TCRRounds.sol`
  - `src/tcr/utils/*.sol`
  - `src/tcr/strategies/*.sol`

## Key Interaction Paths

1. Flow initialization and allocation
- `CustomFlow.initialize` -> `Flow.__Flow_init` -> `FlowInitialization` checks.
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
- Goal-ledger child allocation sync executes through `GoalFlowAllocationLedgerPipeline` with best-effort call semantics and explicit observability events.
- Init-only flow deployment knobs:
  - `flowImpl` and `managerRewardPoolFlowRatePercent` are configured
    only at initialization time.
  - Corresponding runtime setter entrypoints are removed from the flow surface.
- `BudgetTCR` also provides permissionless best-effort budget treasury batch sync (`syncBudgetTreasuries`) for keeper-style liveness:
  - skips undeployed/inactive items,
  - continues when individual treasury `sync()` calls fail.
- Flow rate mutators are role-gated:
  - `setTargetOutflowRate` and `refreshTargetOutflowRate`: flow-operator/parent.

3. Goal treasury funding and resolution
- Revnet ingress arrives through `GoalRevnetSplitHook.processSplitWith`.
- `GoalTreasury.recordHookFunding` and `sync`/`activate` govern transitions.
- Goal treasury supports direct donation ingress while funding is open:
  - `donateUnderlyingAndUpgrade(amount)` (auto-upgrade then transfer),
  - donation receipts are included in `totalRaised` (telemetry).
- Goal treasury min-raise lifecycle gating is balance-based (`superToken.balanceOf(flow)`), not `totalRaised`, so direct flow inflows can satisfy activation.
- Goal treasury target computation is spend-pattern driven (linear pattern locked at present).
- For active linear spend-down, goal sync adds a proactive buffer-derived liquidation-horizon cap when the linear target is currently buffer-affordable; write-time fallback behavior remains best-effort.
- Goal and budget treasuries share thin mechanics via `TreasuryBase` (donation ingress wrappers, treasury-balance reads, and flow-zero helper), while retaining separate lifecycle/economic policy logic.
- Success state transition no longer requires all RewardEscrow-tracked budgets resolved.
- Finalization path still triggers flow stop + residual settlement + stake-vault resolution.
- Reward escrow success-finalization behavior:
  - treasury may defer reward escrow finalize during `resolveSuccess` when tracked budgets remain unresolved;
  - escrow finalize is retried permissionlessly through terminal-side-effect retries once tracked budgets resolve;
  - escrow/ledger snapshots use the recorded success timestamp for point accrual cutoffs while budget success eligibility is based on final resolved outcome (no `resolvedAt <= successAt` gate).
- Residual settlement behavior:
  - `Succeeded`: settle goal-flow SuperToken balance and split by `successSettlementRewardEscrowPpm` (reward escrow + controller burn).
  - `Failed`/`Expired`: settle and burn 100% via controller.
- Post-finalization late inflows can be settled by calling `GoalTreasury.settleLateResidual()` to apply the same state-dependent residual policy.
- Failed escrow sweeps apply terminal handling for both tracked assets:
  - goal-token rewards burn via controller in `GoalTreasury.sweepFailedRewards()`,
  - cobuild rewards also burn via controller in the same call using `cobuildRevnetId` (defaults to `goalRevnetId`).
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
  - Success-settlement path while treasury state is `Succeeded` and minting remains open.
  - Closed nonterminal path defers split funds on treasury.
  - Terminal closed path applies treasury terminal settlement policy.
- Success-settlement split ratio is immutable per treasury deployment (`successSettlementRewardEscrowPpm` config).

4. Budget treasury lifecycle
- Budget treasury uses live treasury balance (`superToken.balanceOf(flow)`) for activation/expiry checks.
- Budget treasury supports direct donation ingress while funding is open:
  - `donateUnderlyingAndUpgrade(amount)`.
- Activation threshold and execution-duration semantics govern outflow windows.
- Active target flow-rate is trusted parent member flow-rate (`parent.getMemberFlowRate(child)`) only (pass-through budget invariant).
- Budget terminal resolution settles residual child-flow SuperToken balance back to the parent goal flow.
- Post-finalization late child-flow inflows can be settled with `BudgetTreasury.settleLateResidualToParent()`.

5. Stake and reward path
- `GoalStakeVault` tracks dual-asset stake and allocation weight.
- `GoalStakeVault` can charge continuous rent on both stake assets (lazy accrual, withheld on withdraw, routed to reward escrow).
- `GoalStakeVault` maps caller identity to live vault weight for goal-flow allocation via built-in strategy methods.
- `BudgetFlowRouterStrategy` maps caller identity to per-budget stake tracked in `BudgetStakeLedger` using caller-flow context (`msg.sender` child flow -> registered recipient id); checkpointed stake is quantized to Flow unit-weight resolution so sub-unit dust is ignored.
- `BudgetStakeLedger` applies maturation on that effective unit-scale stake: each user/budget increment starts as fully unmatured and decays over time before contributing full reward-point rate. The maturation period is derived from the budget scoring-window length (`window / 10`, clamped to `[1 second, 30 days]`) instead of budget `executionDuration`.
- `RewardEscrow` snapshots successful-budget points from `BudgetStakeLedger` at goal finalization; points are window-normalized (`raw matured stake-time / scoring-window seconds`) and budget raw accrual stops at the earliest exogenous cutoff (`activatedAt`, `fundingDeadline`, goal success, or removal), so longer funding deadlines do not linearly increase point yield for the same support pattern.
- `RewardEscrow` recognizes budget recipients either directly (budget treasury recipient) or via child-flow recipient admin (`recipientAdmin`, typically the budget treasury).
- When configured with a goal SuperToken manager-reward stream, `RewardEscrow` can permissionlessly unwrap to goal-token balances and finalization snapshots normalized pools.
- `RewardEscrow.claim` now handles both one-time snapshot rewards and incremental rent redistribution using per-point indexes for post-finalize rent inflows.

6. TCR request/challenge/dispute lifecycle
- Item add/remove -> challenge window -> dispute creation in arbitrator.
- Arbitrator ruling feeds back into TCR status resolution and reward accounting.
- In stake-vault mode, delegated commit (`commitVoteFor`) and permissionless per-voter slashing (`slashVoter`) are enabled.
- Slash settlement is sourced from the juror's live stake balances (not only currently locked juror balances), then routed to goal reward escrow.

7. Budget TCR stack lifecycle
- Accepted Budget TCR items deploy stake-vault + child flow + budget treasury stack and reuse one shared per-goal budget router strategy.
- Budget stack activation no longer deploys a per-budget temporary manager contract or does post-deploy authority handoff:
  - `BudgetTCR` creates the child-flow recipient with explicit child roles (`recipientAdmin`, `flowOperator`, `sweeper`),
  - current stack wiring sets those roles to the cloned budget treasury address during creation.
- `BudgetFlowRouterStrategy` uses contextual flow routing:
  - `BudgetTCR` registers each newly deployed child flow once (`childFlow -> recipientId`) through the stack deployer,
  - strategy resolves effective budget address via `BudgetStakeLedger.budgetForRecipient(recipientId)` and fails closed when missing/resolved.
- `BudgetTCRDeployer` uses clone-first treasury setup:
  - it deploys an uninitialized treasury clone during `prepareBudgetStack`,
  - `GoalStakeVault.goalTreasury` is anchored to that real clone address,
  - treasury initialization happens in `deployBudgetTreasury` after child-flow creation.
- `BudgetTCR` now performs runtime parent-flow recipient add/remove operations directly.
- On accepted removal, budget child outflow is force-zeroed immediately; stack terminalization then follows terminal-only retries via `BudgetTCR.retryRemovedBudgetResolution(...)`.
- On accepted removal, `BudgetTCR` disables budget success resolution only for non-locked/pre-activation removals; activation-locked removals preserve reward-history/success-eligibility paths while still terminalizing through retries.
- `BudgetTCRDeployer` remains `onlyBudgetTCR` and mechanical (`prepareBudgetStack` + `deployBudgetTreasury`).
- `BudgetTreasury` is controller-gated (initializer-set one-time controller, no ownership transfer/renounce surface).
- Treasury authority reads are standardized:
  - canonical surface is `ITreasuryAuthority.authority()`,
  - `GoalStakeVault` reads `authority()` directly from configured `goalTreasury` (no forwarder indirection).
- For add/remove recipient calls, the goal flow `recipientAdmin` should be set to the per-goal `BudgetTCR`.
- `BudgetTCRFactory` consumes a caller-provided `IVotes` token and clones pre-deployed `BudgetTCR`, `ERC20VotesArbitrator`, and `BudgetTCRDeployer` implementations.
- `BudgetTCRFactory.deployBudgetTCRStackForGoal` is restricted to one configured caller (the deployment `GoalFactory`), removing permissionless external access.
- Invalid/no-vote arbitrator round rewards are routed to a configured `invalidRoundRewardSink`.

## Test Harness Boundaries

- `test/goals/helpers/RevnetTestHarness.sol` uses a local ruleset simulator (`RevnetTestRulesets`) for 0.8.34 compatibility.
- This harness is not a canonical Nana/JBX implementation; parity/spec-lock tests in `test/goals/GoalRevnetIntegration.t.sol` define and protect the relied-upon behavior.

## Architecture Invariants

1. Allocation determinism
- Allocation updates are commitment-validated and should remain deterministic and auditable.
- Previous committed allocation weight is sourced on-chain from `allocWeightPlusOne`.
- `BudgetStakeLedger.checkpointAllocation` enforces sorted/unique recipient-id ordering to keep linear merge checkpoints sound.
- `BudgetStakeLedger.checkpointAllocation` fails closed on stored-vs-expected allocation drift (no silent reconciliation/clamping).
- `allocationPipeline` is configured at flow initialization and validated fail-fast during init.
- Goal-flow allocation-ledger mode validation is enforced by `GoalFlowAllocationLedgerPipeline` via `GoalFlowLedgerMode`,
  including strategy compatibility checks (such as empty-aux `allocationKey(account, "")` probing).
- Pipeline instances with `allocationLedger == 0` are explicit no-op mode and do not checkpoint.
- Goal-flow ledger checkpoint writes and child-sync enforcement/execution are delegated to the configured post-commit
  pipeline (`src/hooks/GoalFlowAllocationLedgerPipeline.sol`) after allocation commit success.
- Architecture decision (2026-02-24): allocation child-sync side effects are best-effort and should not hard-revert
  parent allocation maintenance paths. Failures are expected to remain observable and permissionlessly repairable via
  `syncAllocation` / `clearStaleAllocation` worker/keeper calls.
- Implementation note: unresolved targets emit `ChildAllocationSyncSkipped(..., "TARGET_UNAVAILABLE")`; failed child
  sync calls emit `ChildAllocationSyncAttempted(..., success=false)` while parent allocation maintenance continues.
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
- Goals/treasury/stake/reward: `test/goals/*.t.sol`
- TCR/arbitrator: `test/GeneralizedTCR*.t.sol`, `test/ERC20VotesArbitrator*.t.sol`, `test/TCRRounds.t.sol`, `test/SubmissionDepositStrategies.t.sol`, `test/BudgetTCR.t.sol`
- Invariants: `test/invariant/*.t.sol`
- Upgrades/harness/mocks: `test/upgrades/*.sol`, `test/harness/*.sol`, `test/mocks/*.sol`

## Verification Defaults

- `forge build -q`
- `pnpm -s test:lite`
- `pnpm -s test:coverage:ci` for CI coverage gates
- `pnpm -s slither` for local static analysis (if installed)

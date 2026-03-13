# Goal Funding and Underwriting Map

Hard-cutover note (2026-03-01): the legacy goal RewardEscrow / points subsystem is removed from runtime code. This map describes the current funding, premium, and slashing model after the preset refactor.

## Preset Summary

- Both presets use the same goal funding vault: `StakeVault`.
- `StakeVault` is not always the allocator:
  - open preset: `StakeVault` is the goal-flow allocator and the funding / coverage vault,
  - managed preset: `StakeVault` still holds funding / coverage state, but goal-flow allocation authority comes from `SingleAllocatorStrategy` with `ManagedBudgetController` as allocator identity.
- Budget controllers are now pluggable:
  - open preset: `BudgetTCR`
  - managed preset: `ManagedBudgetController`
- Premium / risk modules are now pluggable:
  - open preset: `PremiumEscrow`
  - managed preset: none by default (`premiumEscrow = address(0)` / `premiumEscrowImplementation = address(0)`)
- Managed child-budget admin and allocator identity are both controller-centric; Safe authority operates through `ManagedBudgetController`.
- Advisory TCR for maintainer goals and any managed mechanism controller are intentionally out of scope for this pass.

## Community Root Routing Path

1. A payer routes an evergreen community revnet payment through `CobuildCommunityTerminal`.
2. `CobuildCommunityTerminalFactory.deployFor(...)` deterministically deploys the community-scoped `CobuildSplitHook`, initializes it with the shared `CobuildCommunityTerminal` as fixed `routeSetter`, and registers the community on that terminal in the same transaction through the terminal's approved-factory path.
3. Outside the factory flow, community registration is a direct project-owner call on `CobuildCommunityTerminal`; there is no offchain-signature registration path.
4. Registration fail-closes unless the community revnet's live reserved-token split group already resolves to the predicted hook for the current ruleset.
5. `CommunityGoalRegistry` remains the canonical onchain source of donor-visible goals.
6. `GoalDeploymentRegistry` remains the canonical onchain source of `goalId -> goalTreasury`.
7. Direct goal funding uses `CobuildGoalTerminal`, which resolves each goal's payment token and source revnet from the registered goal treasury plus stake vault.
8. When community reserved tokens are minted, `CobuildSplitHook` routes either:
   - the explicit one-shot route seeded by the terminal for the current pay, or
   - hook-managed backlog for later permissionless flush.

## Goal Exit Path

1. A holder sends goal tokens to `CobuildExitRouter` and chooses one of three user-facing targets: immediate community token, COBUILD token, or native ETH.
2. The router resolves the goal's immediate upstream denomination from `goalTreasury.cobuildRevnetId()` and `StakeVault.cobuildToken()`.
3. The router cashes out the goal into that immediate layer through the goal project's canonical cash-out terminal and rejects `exitToCommunityToken(...)` unless that first hop is a registered community layer.
4. If the requested target is above that first layer, the router walks `CobuildCommunityTerminal.communityConfigOf(...)` upward in bounded hops:
   - `exitToCobuildToken(...)` stops once the lineage reaches the configured COBUILD root.
   - `exitToEth(...)` stops at a direct-native community root or cashes the COBUILD root out into native ETH.
5. Each community hop is redeemed through `CobuildCommunityTerminal.cashOutTokensOf(...)`, which burns the router-held intermediate community tokens and settles reclaim value from held terminal liquidity; if a community project's primary reclaim terminal is repointed away from the shared terminal, the router fails closed.

## Goal Funding Path

1. Goal funding enters through `GoalRevnetSplitHook.processSplitWith(...)` or direct donation helpers on `GoalTreasury`.
2. `GoalTreasury` accepts funding into the goal flow while `canAcceptHookFunding()` remains true.
3. Goal min-raise lifecycle checks use live flow balance (`superToken.balanceOf(flow)`), not just accounting telemetry.
4. `GoalTreasury.sync()` owns funding activation and active-state target-rate updates through the configured `ISpendPolicy`.
5. The goal flow always sits on the universal recursive-flow substrate; only the configured goal allocation strategy differs by preset.

## Budget Control Planes

### Open preset

1. `BudgetTCR` is the budget controller, topology registry, and open-market budget curation layer.
2. `BudgetStackDeployer` prepares the budget stack:
   - cloned `BudgetTreasury`
   - cloned `PremiumEscrow`
   - shared `BudgetFlowRouterStrategy`
   - optional `AllocationMechanismTCR` layer
3. Open child-flow `recipientAdmin` comes from deployer stack-module config; the default open stack uses the mechanism layer rather than a Safe.
4. Budget enable / disable decisions use stake-backed coverage semantics through `IBudgetGatePolicy` (`StakeCoverageGatePolicy` by default).
5. Permissionless liveness batching is `BudgetTCR.syncBudgetTreasuries(...)`.

### Managed preset

1. `ManagedBudgetController` is the budget controller, topology registry, and goal-level allocator identity.
2. `GoalFactoryManagedPresetDeploy` wires:
   - immutable `SingleAllocatorStrategy` for the goal flow, allocating as `ManagedBudgetController`
   - a cloned `BudgetStackDeployer` sourced from `BudgetTCRFactory.stackDeployerImplementation()` and configured for budget child stacks
   - optional managed gate-policy module wired through `GoalFactory.deployManagedGoal(...)`
   - no premium module (`premiumEscrow = address(0)`, `premiumEscrowImplementation = address(0)`)
3. The managed stack deployer clone only prepares the controller-scoped managed stack pieces:
   - cloned `BudgetTreasury`
   - no premium escrow module
   - controller-owned/controller-allocated `BudgetSingleAllocatorStrategy` from `BudgetSingleAllocatorStrategyFactory`
   The later treasury deployment step uses the explicit no-risk-module stack-instantiation path after the child flow exists.
4. Managed child-flow `recipientAdmin` is `ManagedBudgetController`, and Safe authority operates through controller entrypoints.
5. Safe-managed mechanism runtimes such as `TeamFlow` may still be deployed directly from their factories and attached as ordinary managed budget-flow recipients through the controller's generic recipient APIs; this path does not use `AllocationMechanismTCR` or `MechanismFundingEscrow`.
6. Managed preset does not require real premium accounting, does not depend on underwriter coverage to enable active budgets, and does not deploy a managed mechanism layer.
7. Permissionless liveness batching is `ManagedBudgetController.syncBudgetTreasuries(...)`; when a treasury `sync()` leaves a managed budget terminal, the controller prunes recipient/topology state locally in that same batch instead of relying on the treasury's callback reentry path.
8. Authority-gated child-budget allocation writes route through `ManagedBudgetController.setBudgetFlowWeights(...)`.

## Budget Lifecycle and Risk Modules

1. Parent funding reaches each budget as a child flow under the goal flow.
2. In both presets, the budget treasury remains the child `flowOperator` and `sweeper`.
3. `BudgetTreasury` is controller-gated through `IBudgetController`, not `BudgetTCR` specifically.
4. Budget active target-rate computation is still policy-driven through `ISpendPolicy`.
5. Terminal pruning is controller-owned through `IBudgetController.pruneTerminalBudget(...)`:
   - open preset implementation: `BudgetTCR`
   - managed preset implementation: `ManagedBudgetController`

### Open preset risk path

- Manager reward stream routes into `PremiumEscrow` at `budgetPremiumPpm`.
- Goal-level `UnderwriterSlasherRouter` wiring is present only when `budgetSlashPpm != 0`; premium-only/no-slash budgets still use `PremiumEscrow` but omit goal-level slasher routing.
- Budget activation fail-closes on prepared stack shape: nonzero strategy/treasury/mechanism, mechanism-owned child recipient admin, and premium presence exactly matching the configured premium/slash lane.
- `PremiumEscrow` checkpoints live coverage from `BudgetStakeLedger`, accrues premium, gates claims on goal success, and can slash underwriters through `UnderwriterSlasherRouter`.
- Coverage-based recipient enable / disable remains part of the live routing path.
- When `BudgetTCR.syncBudgetTreasuries(...)` terminalizes a budget after a successful treasury sync, the controller also prunes the parent recipient and best-effort syncs the goal treasury locally in that same batch; the treasury callback remains a retryable fallback path.

### Managed preset risk path

- Managed budget child flows do not configure a premium escrow or manager-reward premium route by default.
- Managed controller no longer stores `budgetAllocationLedger`, `underwriterSlasherRouter`, `budgetPremiumPpm`, or `budgetSlashPpm`.
- Managed controller initialization fail-closes on stack-deployer preset traits (`Factory` child strategy target with code, no mechanism layer, controller-owned child admin, no premium implementation) and rejects zero budget success-assertion liveness.
- Managed budget creation fail-closes on prepared stack shape: nonzero strategy/treasury, zero mechanism layer, zero premium module, and `childFlowRecipientAdmin == address(controller)`.
- No premium escrow is initialized, connected, or authorized for managed budgets by default.
- Managed goals also leave `StakeVault.jurorSlasher()` unset; juror-slasher routing remains open-preset-only.
- Managed preset deployment rejects nonzero `budgetPremiumPpm` or `budgetSlashPpm`.
- Managed goal-treasury success residuals do not use burn-only settlement:
  - on `Succeeded`, `GoalTreasury` cashes out residual goal-token value into the parent/community token through the canonical goal cash-out terminal,
  - it queues that amount on the canonical community split hook with the fixed managed rollover cooldown,
  - after cooldown, anyone can release queued rollover amounts into historical backlog so the existing decayed split-hook weights route them,
  - `Expired` remains burn-only.
- Managed removals now fail-close at the treasury layer for both funding and activated budgets: `ManagedBudgetController.removeBudget(...)` detaches the parent recipient, terminalizes through the controller-only removal path, and best-effort syncs the goal treasury inline, so later `BudgetTreasury.sync()` calls cannot restart payout.
- Managed controller-owned terminalization during `syncBudgetTreasuries(...)` also performs the parent prune locally after a successful terminalizing `treasury.sync()`, avoiding the controller's own reentrancy guard while preserving the treasury callback as a retryable external path.

## Stake, Coverage, and Reward Semantics

- `StakeVault` still tracks goal and cobuild stake, juror locks, underwriter coverage, and withdrawal preparation.
- Open preset uses `StakeVault` weight directly for goal allocation.
- Managed preset still uses `StakeVault` for funding / coverage state, but not for goal allocator identity.
- `BudgetStakeLedger` remains coverage-only accounting for per-user / per-budget allocated stake plus checkpoint history.
- `UnderwriterSlasherRouter` still receives slash outcomes from real `PremiumEscrow` flows in the open preset and forwards recovered value toward goal funding.
- `StakeVault.prepareUnderwriterWithdrawal(maxBudgets)` is only a post-resolution withdrawal prerequisite on slash-enabled goals; zero-slash goals skip the no-op prepare step.
- Budget success-assertion bond is pass-through config on both presets; `0` means the downstream UMA resolver floors to its configured minimum bond instead of being rejected at controller/TCR initialization.
- Managed preset skips live premium / slash accounting by deploying budget stacks with no premium module configured.

## Deferred Follow-Ups

- Advisory TCR for managed / maintainer goals: deferred
- Managed mechanism controller / managed mechanism registry: deferred

## Key Files

- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/StakeVault.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/ManagedBudgetController.sol`
- `src/tcr/BudgetTCR.sol`
- `src/goals/BudgetStackDeployer.sol`
- `src/interfaces/IBudgetStackDeployer.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/juicebox/CobuildExitRouter.sol`
- `src/juicebox/CobuildGoalTerminal.sol`
- `src/juicebox/CobuildCommunityTerminal.sol`

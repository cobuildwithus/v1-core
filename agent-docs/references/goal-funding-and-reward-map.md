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
  - managed preset: `NullPremiumEscrow`
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

## Goal Funding Path

1. Goal funding enters through `GoalRevnetSplitHook.processSplitWith(...)` or direct donation helpers on `GoalTreasury`.
2. `GoalTreasury` accepts funding into the goal flow while `canAcceptHookFunding()` remains true.
3. Goal min-raise lifecycle checks use live flow balance (`superToken.balanceOf(flow)`), not just accounting telemetry.
4. `GoalTreasury.sync()` owns funding activation and active-state target-rate updates through the configured `ISpendPolicy`.
5. The goal flow always sits on the universal recursive-flow substrate; only the configured goal allocation strategy differs by preset.

## Budget Control Planes

### Open preset

1. `BudgetTCR` is the budget controller, topology registry, and open-market budget curation layer.
2. `BudgetTCRDeployer` prepares the budget stack:
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
   - `ManagedBudgetControllerStackDeployer` for budget child stacks
   - `NoopBudgetGatePolicy`
   - `NullPremiumEscrow`
3. `ManagedBudgetControllerStackDeployer` prepares each managed budget stack with:
   - cloned `BudgetTreasury`
   - cloned `NullPremiumEscrow`
   - controller-owned/controller-allocated `BudgetSingleAllocatorStrategy`
4. Managed child-flow `recipientAdmin` is `ManagedBudgetController`, and Safe authority operates through controller entrypoints.
5. Managed preset does not require real premium accounting, does not depend on underwriter coverage to enable active budgets, and does not deploy a mechanism layer.
6. Permissionless liveness batching is `ManagedBudgetController.syncBudgetTreasuries(...)`, and authority-gated child-budget allocation writes route through `ManagedBudgetController.setBudgetFlowWeights(...)`.

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
- `PremiumEscrow` checkpoints live coverage from `BudgetStakeLedger`, accrues premium, gates claims on goal success, and can slash underwriters through `UnderwriterSlasherRouter`.
- Coverage-based recipient enable / disable remains part of the live routing path.

### Managed preset risk path

- Manager reward stream routes into `NullPremiumEscrow` to satisfy the same escrow seam without doing premium accounting.
- `NullPremiumEscrow` still records wiring (`budgetTreasury`, `budgetStakeLedger`, `goalFlow`, `underwriterSlasherRouter`, `budgetSlashPpm`) so the topology remains uniform.
- Runtime premium, claim, slash, and burn operations are intentional no-ops.
- Managed preset deployment rejects nonzero `budgetPremiumPpm` or `budgetSlashPpm`.
- Managed removals now fail-close at the treasury layer: `ManagedBudgetController.removeBudget(...)` terminalizes activated removed budgets immediately through the controller-only removal path, so later `BudgetTreasury.sync()` calls cannot restart payout.

## Stake, Coverage, and Reward Semantics

- `StakeVault` still tracks goal and cobuild stake, juror locks, underwriter coverage, and withdrawal preparation.
- Open preset uses `StakeVault` weight directly for goal allocation.
- Managed preset still uses `StakeVault` for funding / coverage state, but not for goal allocator identity.
- `BudgetStakeLedger` remains coverage-only accounting for per-user / per-budget allocated stake plus checkpoint history.
- `UnderwriterSlasherRouter` still receives slash outcomes from real `PremiumEscrow` flows in the open preset and forwards recovered value toward goal funding.
- Managed preset keeps the same wiring seam but intentionally skips live premium / slash accounting through `NullPremiumEscrow`.

## Deferred Follow-Ups

- Advisory TCR for managed / maintainer goals: deferred
- Managed mechanism controller / managed mechanism registry: deferred

## Key Files

- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/StakeVault.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/NullPremiumEscrow.sol`
- `src/goals/ManagedBudgetController.sol`
- `src/goals/ManagedBudgetControllerStackDeployer.sol`
- `src/tcr/BudgetTCR.sol`
- `src/tcr/BudgetTCRDeployer.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/juicebox/CobuildGoalTerminal.sol`
- `src/juicebox/CobuildCommunityTerminal.sol`

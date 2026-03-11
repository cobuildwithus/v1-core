# Module Boundary Map

## Preset / Control-Plane Split

- The recursive-flow substrate is universal across goal presets:
  - `src/Flow.sol`
  - `src/flows/CustomFlow.sol`
  - `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
  - `src/goals/GoalTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/goals/StakeVault.sol`
- `GoalFactory` selects control-plane modules at deployment time. Neutral substrate modules must not branch on managed vs open runtime flags.
- `StakeVault` remains the funding vault in both presets, but it is not always the goal allocator:
  - open preset: `StakeVault` is both funding vault and goal-flow allocator strategy,
  - managed preset: `StakeVault` still holds funding/coverage state, while `SingleAllocatorStrategy` makes the controller contract the goal allocator identity.

### Open preset tuple

- Goal allocator: `src/goals/StakeVault.sol`
- Budget controller / topology registry: `src/tcr/BudgetTCR.sol`
- Budget gate policy: `src/goals/policies/StakeCoverageGatePolicy.sol` through `src/interfaces/IBudgetGatePolicy.sol`
- Budget child strategy: shared `src/allocation-strategies/BudgetFlowRouterStrategy.sol`
- Premium / risk module: `src/goals/PremiumEscrow.sol`
- Mechanism layer: `src/tcr/AllocationMechanismTCR.sol` via `src/tcr/BudgetTCRDeployer.sol`

### Managed preset tuple

- Goal allocator: `src/allocation-strategies/SingleAllocatorStrategy.sol`
- Goal allocator identity: `src/goals/ManagedBudgetController.sol`
- Budget controller / topology registry: `src/goals/ManagedBudgetController.sol`
- Budget gate policy: pluggable `src/interfaces/IBudgetGatePolicy.sol` (current preset wiring uses `src/goals/NoopBudgetGatePolicy.sol`)
- Budget child strategy: `src/allocation-strategies/BudgetSingleAllocatorStrategy.sol`
- Budget child allocator identity: `src/goals/ManagedBudgetController.sol`
- Premium / risk module: `src/goals/NullPremiumEscrow.sol`
- Stack deployer: `src/goals/ManagedBudgetControllerStackDeployer.sol`
- Mechanism layer: intentionally none in this pass
- Child-flow `recipientAdmin`: Safe-direct in v1; the Safe is not the allocator identity

### Intentional non-goals for this pass

- No advisory TCR for managed / maintainer goals
- No managed mechanism controller or managed analogue of `AllocationMechanismTCR`

## Core Domain Boundaries

### Flow domain

- Contracts: `src/Flow.sol`, `src/flows/CustomFlow.sol`
- Team/team-lane runtimes: `src/teamflow/TeamFlow.sol`, `src/teamflow/TeamFlowFactory.sol`
- Libraries: `src/library/Flow*.sol`, `src/library/CustomFlowLibrary.sol`
- Strategies: `src/allocation-strategies/*.sol`, plus `src/goals/StakeVault.sol` as the open-preset goal strategy implementation
- Interfaces:
  - `src/interfaces/IFlow.sol`
  - `src/interfaces/IManagedFlow.sol`
  - `src/interfaces/IAllocationStrategy.sol`
  - `src/interfaces/IAllocationPipeline.sol`
  - `src/interfaces/IGoalScopedAllocationStrategy.sol`
  - `src/interfaces/IGoalLedgerStrategy.sol` (legacy alias only)
- Flow allocation pipeline modules: `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- External-read boundary: `CustomFlow` owns canonical allocation-read helpers; strategies and pipeline previews consume explicit `flow` context instead of inferring it from `msg.sender`.

### Goals / treasury / controller domain

- Contracts:
  - `src/goals/TreasuryBase.sol`
  - `src/goals/GoalTreasury.sol`
  - `src/goals/GoalDeploymentRegistry.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/goals/StakeVault.sol`
  - `src/goals/BudgetStakeLedger.sol`
  - `src/goals/PremiumEscrow.sol`
  - `src/goals/NullPremiumEscrow.sol`
  - `src/goals/ManagedBudgetController.sol`
  - `src/goals/ManagedBudgetControllerStackDeployer.sol`
  - `src/goals/UnderwriterSlasherRouter.sol`
  - `src/goals/UMATreasurySuccessResolver.sol`
  - `src/goals/policies/*.sol`
- Libraries: `src/goals/library/*.sol`
- Hook ingress: `src/hooks/GoalRevnetSplitHook.sol`, `src/hooks/CobuildSplitHook.sol`
- Shared payment terminals:
  - `src/juicebox/CobuildGoalTerminal.sol`
  - `src/juicebox/CobuildCommunityTerminal.sol`
  - `src/juicebox/CobuildCommunityTerminalFactory.sol`
- Interfaces:
  - `src/interfaces/IGoalTreasury.sol`
  - `src/interfaces/IBudgetTreasury.sol`
  - `src/interfaces/IBudgetController.sol`
  - `src/interfaces/IBudgetGatePolicy.sol`
  - `src/interfaces/IBudgetStackTopologyReader.sol`
  - `src/interfaces/ISpendPolicy.sol`
  - `src/interfaces/IStakeVault.sol`
  - `src/interfaces/IBudgetStakeLedger.sol`
  - `src/interfaces/IPremiumEscrow.sol`
  - `src/interfaces/IUnderwriterSlasherRouter.sol`
  - `src/interfaces/ITreasuryAuthority.sol`
  - `src/interfaces/ICobuildSplitHook.sol`
- Community-routing boundary: `CommunityGoalRegistry` owns selectable-goal membership plus metadata, `GoalDeploymentRegistry` owns canonical `goalId -> goalTreasury`, `CobuildCommunityTerminalFactory` owns canonical split-hook deployment plus same-tx community-terminal registration, `CobuildCommunityTerminal` owns per-community pay routing, and `CobuildGoalTerminal` owns per-goal funding-context resolution.

### TCR / arbitration / open-stack deployment domain

- Core: `src/tcr/GeneralizedTCR.sol`, `src/tcr/ERC20VotesArbitrator.sol`, `src/tcr/BudgetTCR.sol`, `src/tcr/CommunityGoalRegistry.sol`
- Open budget stack orchestration: `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/BudgetTCRFactory.sol`
- Mechanism registry / factory boundary: `src/tcr/AllocationMechanismTCR.sol`, `src/tcr/interfaces/IAllocationMechanismFactory.sol`
- Supporting modules: `src/tcr/interfaces/**`, `src/tcr/storage/**`, `src/tcr/library/**`, `src/tcr/utils/**`, `src/tcr/strategies/**`

## Boundary Rules

1. Keep cross-domain dependencies explicit through interfaces instead of preset-specific concrete types.
2. `BudgetTreasury` depends on `IBudgetController`, not directly on `BudgetTCR`.
3. Goal-flow `recipientAdmin` is the per-goal budget controller / topology registry:
   - open preset: `BudgetTCR`
   - managed preset: `ManagedBudgetController`
4. Child-flow `recipientAdmin` is preset-specific and must not be inferred from the goal-flow controller:
   - open preset: chosen by `BudgetTCRDeployer` stack-module config,
   - managed preset: Safe-direct in v1.
5. Goal-flow child-sync and budget-ledger registration discover topology through `IBudgetStackTopologyReader` (`budgetTreasury.authority()` / `goalFlow.recipientAdmin()`), not by assuming `BudgetTCR` is the only controller.
6. Gate policies own enable/disable decisions only; controller modules own routing writes, terminal prune, and best-effort sync retries.
7. Keep community goal-curation, deployment-registry ownership, and treasury beneficiary resolution explicit; do not infer them from ad hoc runtime probes.
8. Treat storage modules as upgrade-sensitive boundaries and keep tests aligned to these seams.

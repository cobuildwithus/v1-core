# Module Boundary Map

## Core Domain Boundaries

### Planned preset/control-plane boundary

- Neutral substrate stays shared across presets: `Flow`, `CustomFlow`, `GoalFlowAllocationLedgerPipeline`, `GoalTreasury`, `BudgetTreasury`, and `StakeVault` must stay free of hidden `isManaged` runtime branching.
- Open-goal control plane stays on the current open-market stack: `BudgetTCR`, current credit-cap policy, current premium escrow path, and current mechanism-registry semantics.
- Managed maintainer-goal control plane is a deployment-time alternative tuple:
  - controller: `ManagedBudgetController` via generic `IBudgetController`
  - gate policy: `IBudgetGatePolicy`
  - goal-scoped allocation strategy: `SingleAllocatorStrategy` via `IGoalScopedAllocationStrategy`
  - escrow: `NullPremiumEscrow`
- Boundary rule: controller-owned routing and terminal-prune behavior stay separate from pluggable gate-policy coverage decisions.
- Boundary rule: `BudgetTreasury` must depend on a generic controller interface, not `IBudgetTCR`.

### Flow domain

- Contracts: `src/Flow.sol`, `src/flows/CustomFlow.sol`
- Team/team-lane runtimes: `src/teamflow/TeamFlow.sol`, `src/teamflow/TeamFlowFactory.sol`
- Libraries: `src/library/Flow*.sol`, `src/library/CustomFlowLibrary.sol`
- Strategies: `src/allocation-strategies/*.sol`
- Interfaces: `src/interfaces/IFlow.sol`, `src/interfaces/IManagedFlow.sol`, `src/interfaces/IAllocationStrategy.sol`, `src/interfaces/IAllocationPipeline.sol`, `src/interfaces/IGoalLedgerStrategy.sol`
- Flow allocation pipeline modules: `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- External-read boundary: `CustomFlow` owns canonical allocation-read helpers; strategies/pipeline previews consume explicit `flow` context instead of inferring it from `msg.sender`.

### Goals/treasury domain

- Contracts: `src/goals/TreasuryBase.sol`, `src/goals/GoalTreasury.sol`, `src/goals/GoalDeploymentRegistry.sol`, `src/goals/BudgetTreasury.sol`, `src/goals/StakeVault.sol`, `src/goals/BudgetStakeLedger.sol`, `src/goals/PremiumEscrow.sol`, `src/goals/UnderwriterSlasherRouter.sol`, `src/goals/UMATreasurySuccessResolver.sol`, `src/goals/policies/*.sol`
- Libraries: `src/goals/library/*.sol`
- Hook ingress: `src/hooks/GoalRevnetSplitHook.sol`, `src/hooks/CobuildSplitHook.sol`
- Shared goal/community payment terminals: `src/juicebox/CobuildGoalTerminal.sol`, `src/juicebox/CobuildCommunityTerminal.sol`, `src/juicebox/CobuildCommunityTerminalFactory.sol`
- Interfaces: `src/interfaces/IGoalTreasury.sol`, `src/interfaces/IBudgetTreasury.sol`, `src/interfaces/ISpendPolicy.sol`, `src/interfaces/IStakeVault.sol`, `src/interfaces/IBudgetStakeLedger.sol`, `src/interfaces/IPremiumEscrow.sol`, `src/interfaces/IUnderwriterSlasherRouter.sol`, `src/interfaces/ITreasuryAuthority.sol`, `src/interfaces/ICobuildSplitHook.sol`
- Community-routing boundary: `CommunityGoalRegistry` owns selectable-goal membership plus metadata, `GoalDeploymentRegistry` owns canonical `goalId -> goalTreasury`, `CobuildCommunityTerminalFactory` owns canonical split-hook deployment plus same-tx community-terminal registration against a shared route setter, `CobuildCommunityTerminal` owns per-community immutable registration + pay-time routing, `CobuildGoalTerminal` owns per-goal funding-context resolution, and `CobuildSplitHook` remains a thin router that reads both fixed registries plus observed explicit-volume history.

### TCR/arbitration domain

- Core: `src/tcr/GeneralizedTCR.sol`, `src/tcr/ERC20VotesArbitrator.sol`, `src/tcr/BudgetTCR.sol`, `src/tcr/CommunityGoalRegistry.sol`
- Budget stack orchestration: `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/BudgetTCRValidator.sol`, `src/tcr/BudgetTCRFactory.sol`
- Mechanism registry/factory boundary: `src/tcr/AllocationMechanismTCR.sol`, `src/tcr/interfaces/IAllocationMechanismFactory.sol`
- Support: `src/tcr/interfaces/**`, `src/tcr/storage/**`, `src/tcr/library/**`, `src/tcr/utils/**`, `src/tcr/strategies/**`

## Boundary Rules

1. Keep cross-domain dependencies explicit via interfaces.
2. Keep funds/lifecycle coupling paths documented when they cross domains.
3. Keep community goal-curation and treasury-sink ownership/source explicit; do not infer downstream treasury beneficiaries from ad hoc runtime probes.
3. Treat storage modules as upgrade-sensitive boundaries.
4. Keep domain tests aligned to these boundaries.

# Module Boundary Map

## Core Domain Boundaries

### Flow domain

- Contracts: `src/Flow.sol`, `src/flows/CustomFlow.sol`
- Libraries: `src/library/Flow*.sol`, `src/library/CustomFlowLibrary.sol`
- Strategies: `src/allocation-strategies/*.sol`
- Interfaces: `src/interfaces/IFlow.sol`, `src/interfaces/IManagedFlow.sol`, `src/interfaces/IAllocationStrategy.sol`, `src/interfaces/IAllocationPipeline.sol`, `src/interfaces/IGoalLedgerStrategy.sol`
- Flow allocation pipeline modules: `src/hooks/GoalFlowAllocationLedgerPipeline.sol`

### Goals/treasury domain

- Contracts: `src/goals/TreasuryBase.sol`, `src/goals/GoalTreasury.sol`, `src/goals/BudgetTreasury.sol`, `src/goals/StakeVault.sol`, `src/goals/BudgetStakeLedger.sol`, `src/goals/PremiumEscrow.sol`, `src/goals/UnderwriterSlasherRouter.sol`, `src/goals/UMATreasurySuccessResolver.sol`, `src/goals/policies/*.sol`
- Libraries: `src/goals/library/*.sol`
- Hook ingress: `src/hooks/GoalRevnetSplitHook.sol`, `src/hooks/CobuildSplitHook.sol`
- Community payment wrapper: `src/juicebox/CobuildPaymentTerminal.sol`
- Interfaces: `src/interfaces/IGoalTreasury.sol`, `src/interfaces/IBudgetTreasury.sol`, `src/interfaces/ISpendPolicy.sol`, `src/interfaces/IStakeVault.sol`, `src/interfaces/IBudgetStakeLedger.sol`, `src/interfaces/IPremiumEscrow.sol`, `src/interfaces/IUnderwriterSlasherRouter.sol`, `src/interfaces/ITreasuryAuthority.sol`, `src/interfaces/ICobuildSplitHook.sol`
- Community-routing curation boundary: `CommunityGoalRegistry` owns selectable-goal membership plus goal-treasury sink metadata, while `CobuildSplitHook` remains a thin router that reads registry state and observed explicit-volume history.

### TCR/arbitration domain

- Core: `src/tcr/GeneralizedTCR.sol`, `src/tcr/ERC20VotesArbitrator.sol`, `src/tcr/BudgetTCR.sol`, `src/tcr/CommunityGoalRegistry.sol`
- Budget stack orchestration: `src/tcr/BudgetTCRDeployer.sol`, `src/tcr/BudgetTCRValidator.sol`, `src/tcr/BudgetTCRFactory.sol`
- Support: `src/tcr/interfaces/**`, `src/tcr/storage/**`, `src/tcr/library/**`, `src/tcr/utils/**`, `src/tcr/strategies/**`

## Boundary Rules

1. Keep cross-domain dependencies explicit via interfaces.
2. Keep funds/lifecycle coupling paths documented when they cross domains.
3. Keep community goal-curation and treasury-sink metadata explicit; do not infer downstream treasury beneficiaries from ad hoc runtime probes.
3. Treat storage modules as upgrade-sensitive boundaries.
4. Keep domain tests aligned to these boundaries.

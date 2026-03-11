# Flow Allocation and Child Sync Map

## Universal Substrate

- The recursive flow substrate is shared across presets:
  - `Flow`
  - `CustomFlow`
  - `GoalFlowAllocationLedgerPipeline`
  - `GoalFlowLedgerMode`
- Flow runtime code does not branch on managed vs open preset selection.
- Goal-flow allocation uses the same runtime hooks in both presets:
  - `allocationKey(account, "")`
  - `currentWeight(flow, key)`
  - `canAllocate(flow, key, caller)`

## Goal Allocator Presets

- Open preset:
  - goal funding vault: `StakeVault`
  - goal allocator strategy: `StakeVault`
  - allocator weight source: live stake weight
- Managed preset:
  - goal funding vault: `StakeVault`
  - goal allocator strategy: `SingleAllocatorStrategy`
  - allocator identity: `ManagedBudgetController`
  - Safe rotation does not change goal allocator identity because the controller owns the managed goal strategy

## Allocation Path

1. `CustomFlow.allocate` validates allocation vectors.
2. Flow initialization configures exactly one default strategy and exposes it via `strategy()`.
3. Default allocation resolves `allocationKey(caller, "")`, passes explicit `flow` context into the strategy, loads previous snapshot state, and resolves previous weight from on-chain cache (`allocWeightPlusOne`).
4. Allocation commitment hashes remain canonical over recipient ids plus scaled allocation vectors; weight is tracked separately.
5. Allocation edits are applied through typed `FlowAllocations` helpers with structural validation and previous-state continuity checks.
6. After a successful commit, `CustomFlow` invokes the configured allocation pipeline.
7. With `GoalFlowAllocationLedgerPipeline` configured with a non-zero ledger, checkpoints are written to `BudgetStakeLedger`.
8. `GoalFlowLedgerMode` validates that the configured goal strategy satisfies the goal-scoped strategy boundary (`IGoalScopedAllocationStrategy`; `IGoalLedgerStrategy` remains a legacy alias).
9. Pipeline instances with `allocationLedger == 0` remain explicit no-op mode.

## Child Sync Target Discovery

- Changed budget treasuries come from `BudgetStakeLedger.checkpointAllocation(...)` or its preview twin.
- Child-sync target discovery is controller-neutral:
  - `GoalFlowLedgerMode` reads `budgetTreasury.authority()`,
  - that authority must implement `IBudgetStackTopologyReader`,
  - current concrete registries are `BudgetTCR` for open goals and `ManagedBudgetController` for managed goals.
- Target resolution still fail-closes unless:
  - the controller reports an active topology for that budget treasury,
  - the live child flow exists,
  - the live child flow's configured strategy matches controller-reported topology,
  - the child strategy round-trips `allocationKey(account, "")` back to the same account,
  - the child flow already has a commitment for that `(strategy, allocationKey)`.
- Managed controllers may report zero `allocationMechanism` / `allocationMechanismArbitrator` fields; child sync does not depend on mechanism topology.

## Child Strategy Shapes

- Open preset child flows usually use shared `BudgetFlowRouterStrategy`, which maps allocator accounts to checkpointed stake in `BudgetStakeLedger`.
- Managed preset child flows use `BudgetSingleAllocatorStrategy`, which scopes one allocator key to one budget treasury flow.
- Managed live routing does not depend on underwriter coverage semantics in the child-allocation path; coverage-based enable/disable decisions remain a controller / gate-policy concern.

## Execution and Debt

1. Child sync execution remains best-effort per target.
2. Unresolved targets are skipped with `TARGET_UNAVAILABLE`; missing child commits are skipped with `NO_COMMITMENT`.
3. Allocation-edit commits open per-account child-sync debt on gas-budget skips (`GAS_BUDGET`) and attempted child-sync call failures.
4. Maintenance-sync commits (`syncAllocation`, `syncAllocationForAccount`, `clearStaleAllocation`) are debt-clear-only: they may clear existing debt but do not open new debt on skip/failure.
5. Composition-changing allocation commits fail closed with `ACCOUNT_HAS_CHILD_SYNC_DEBT` until debt is cleared.
6. Permissionless repair remains available through `GoalFlowAllocationLedgerPipeline.repairChildSyncDebt(account, budgetTreasury)`.

## Controller-Owned Treasury Sync

- Parent allocation commits do not mutate child target outflow rates directly.
- Child target-rate mutation belongs to child `flowOperator` roles, typically budget treasuries.
- Treasury lifecycle progression is controller-owned and permissionlessly callable:
  - open preset: `BudgetTCR.syncBudgetTreasuries(...)`
  - managed preset: `ManagedBudgetController.syncBudgetTreasuries(...)`

## Key Files

- `src/Flow.sol`
- `src/flows/CustomFlow.sol`
- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `src/library/GoalFlowLedgerMode.sol`
- `src/library/FlowAllocations.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/tcr/BudgetTCR.sol`
- `src/goals/ManagedBudgetController.sol`

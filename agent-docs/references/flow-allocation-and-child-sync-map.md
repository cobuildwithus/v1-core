# Flow Allocation and Child Sync Map

## Allocation Path

1. `CustomFlow.allocate` validates allocation vectors.
2. Flow initialization enforces exactly one configured strategy; default allocation resolves that strategy from storage.
3. Primary allocation entrypoint derives key with `allocationKey(caller, "")`, verifies `canAllocate`, decodes previous
   snapshot state, and resolves previous weight from on-chain cache (`allocWeightPlusOne`).
4. Allocation commitment hashes are canonical over recipient ids + scaled allocation vectors (weight excluded from commit hash).
5. Allocation deltas are applied through `FlowAllocations.applyAllocationWithPreviousStateMemoryUnchecked`
   after caller-boundary validation of input invariants.
6. After successful allocation commit, `CustomFlow` invokes the configured allocation pipeline.
7. With `GoalFlowAllocationLedgerPipeline` configured with a non-zero ledger, checkpoints are written to `BudgetStakeLedger`.
8. When a parent budget stake delta changes and the corresponding child budget flow has an existing commit, child sync
   requirements are derived automatically from current on-chain state.
9. Child sync execution remains best-effort per target: unresolved/no-commit targets are skipped and attempted child
   sync failures are emitted as failed attempts.
10. `GoalFlowAllocationLedgerPipeline` records per-account/per-budget child-sync debt on allocation-edit commits when
   child sync is skipped due to gas budget (`"GAS_BUDGET"`) or when an attempted child sync call fails.
11. Maintenance sync commits (`syncAllocation`, `syncAllocationForAccount`, `clearStaleAllocation`) are debt-clear-only:
    successful child sync clears debt, while skip/failure outcomes do not open new debt.
12. Parent allocation composition maintenance is fail-closed while debt exists for the allocating account
    (`ACCOUNT_HAS_CHILD_SYNC_DEBT`), and debt is cleared permissionlessly via `repairChildSyncDebt(account, budgetTreasury)`.
13. `CustomFlow.previewChildSyncRequirements(...)` exposes the same changed-budget + expected-commit requirement set as a
    read-only helper for SDK/indexer/relayer planning.
14. Parent allocation commits do not run legacy child flow-rate queue processing; target-rate updates are owned by
    treasury/flow-operator sync paths.
15. Parent allocation commits do not call `BudgetTreasury.sync()`; treasury lifecycle progression is handled by direct
    treasury sync calls and permissionless batch sync via `BudgetTCR.syncBudgetTreasuries(...)`.
16. Allocation logging is split deterministically:
   - `AllocationCommitted` always emits latest `(commit, weight)` for every apply/sync.
   - `AllocationSnapshotUpdated` emits packed snapshot bytes only when `commit` changes.
17. `allocationPipeline` is configured during flow initialization and validated before the flow finishes init.
18. Pipeline instances may be configured with `allocationLedger == 0` for explicit no-op mode.
19. Goal-flow ledger mode (`GoalFlowAllocationLedgerPipeline` + `GoalFlowLedgerMode`) validates goal treasury wiring and
    strategy compatibility, including account-based empty-aux probing via `allocationKey(account, "")`.
20. Goal-ledger strategy capability is explicit via `src/interfaces/IGoalLedgerStrategy.sol` and is used by
    `GoalFlowLedgerMode` as the validation capability surface.

## Child Flow Sync Path

- Child flow recipients are tracked as distribution members in parent allocations.
- Goal-ledger child allocation sync executes through `GoalFlowAllocationLedgerPipeline` best-effort actions with
  account-level debt gating and permissionless per-budget repair.
- Budget/goal treasuries own flow-rate mutation via `sync()` and `TreasuryFlowRateSync`.

## Invariants

- Recipient IDs/allocation vectors should remain sorted/unique where required.
- Snapshot ids/scaled-allocation + commit checks and cached previous-weight sourcing prevent silent allocation drift.
- Parent budget stake deltas can trigger immediate child-allocation weight resync without requiring allocator-only access.
- Child sync call failures should remain explicit via emitted execution outcomes (`success=false` / skip reason).
- Composition-changing allocation commits for accounts with unresolved child-sync debt fail closed until debt is repaired or cleared.

## Key Files

- `src/Flow.sol`
- `src/flows/CustomFlow.sol`
- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `src/library/FlowAllocations.sol`
- `src/library/FlowRates.sol`
- `src/library/FlowPools.sol`
- `src/library/FlowRecipients.sol`

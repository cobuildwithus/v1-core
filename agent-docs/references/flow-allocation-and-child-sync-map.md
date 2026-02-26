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
9. Child sync execution is best-effort: unresolved/no-commit targets are skipped and downstream child sync call failures
   are emitted as failed attempts without reverting parent allocation maintenance.
10. `CustomFlow.previewChildSyncRequirements(...)` exposes the same changed-budget + expected-commit requirement set as a
    read-only helper for SDK/indexer/relayer planning.
11. Parent allocation commits do not run legacy child flow-rate queue processing; target-rate updates are owned by
    treasury/flow-operator sync paths.
12. Parent allocation commits do not call `BudgetTreasury.sync()`; treasury lifecycle progression is handled by direct
    treasury sync calls and permissionless batch sync via `BudgetTCR.syncBudgetTreasuries(...)`.
13. Allocation logging is split deterministically:
   - `AllocationCommitted` always emits latest `(commit, weight)` for every apply/sync.
   - `AllocationSnapshotUpdated` emits packed snapshot bytes only when `commit` changes.
14. `allocationPipeline` is configured during flow initialization and validated before the flow finishes init.
15. Pipeline instances may be configured with `allocationLedger == 0` for explicit no-op mode.
16. Goal-flow ledger mode (`GoalFlowAllocationLedgerPipeline` + `GoalFlowLedgerMode`) validates goal treasury wiring and
strategy compatibility, including account-based empty-aux probing via `allocationKey(account, "")`.
17. Goal-ledger strategy capability is explicit via `src/interfaces/IGoalLedgerStrategy.sol` and is used by
`GoalFlowLedgerMode` as the validation capability surface.

## Child Flow Sync Path

- Child flow recipients are tracked as distribution members in parent allocations.
- Goal-ledger child allocation sync executes through `GoalFlowAllocationLedgerPipeline` best-effort actions.
- Budget/goal treasuries own flow-rate mutation via `sync()` and `TreasuryFlowRateSync`.

## Invariants

- Recipient IDs/allocation vectors should remain sorted/unique where required.
- Snapshot ids/scaled-allocation + commit checks and cached previous-weight sourcing prevent silent allocation drift.
- Parent budget stake deltas can trigger immediate child-allocation weight resync without requiring allocator-only access.
- Child sync call failures should remain explicit via emitted execution outcomes (`success=false` / skip reason).

## Key Files

- `src/Flow.sol`
- `src/flows/CustomFlow.sol`
- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `src/library/FlowAllocations.sol`
- `src/library/FlowRates.sol`
- `src/library/FlowPools.sol`
- `src/library/FlowRecipients.sol`

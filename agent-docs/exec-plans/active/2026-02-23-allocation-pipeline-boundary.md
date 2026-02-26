# Allocation Pipeline Boundary Refactor

## Goal
Collapse hook + ledger-mode coupling into a single explicit post-allocation pipeline boundary.

## Scope
- Replace Flow configuration surface `setAllocationHook/setAllocationLedger` with `setAllocationPipeline`.
- Introduce `IAllocationPipeline` and concrete `GoalFlowAllocationLedgerPipeline`.
- Move goal-ledger checkpoint + child-sync orchestration behind the pipeline boundary.
- Remove obsolete hook interface/contract and migrate source/tests/docs.

## Constraints
- Do not modify `lib/**`.
- Preserve allocation commitment/witness semantics and child-sync fail-closed behavior.
- Preserve ledger validation semantics (goal treasury wiring + strategy compatibility).

## Acceptance criteria
- Flow/CustomFlow no longer expose or depend on allocation hook + ledger dual config.
- Goal-ledger checkpointing and child-sync behavior run through `IAllocationPipeline`.
- Legacy hook interface/implementation are removed from active runtime paths.
- Verification passes:
  - `forge build -q`
  - `pnpm -s test:lite:shared`

## Progress log
- 2026-02-23: Plan created.
- 2026-02-23: Added `src/interfaces/IAllocationPipeline.sol` and migrated Flow storage/config/event surface to pipeline-only.
- 2026-02-23: Refactored `src/flows/CustomFlow.sol` to invoke post-commit pipeline calls and emit child-sync events from pipeline execution outputs.
- 2026-02-23: Added `src/hooks/GoalFlowAllocationLedgerPipeline.sol` and routed ledger validation/checkpoint + child-sync coverage/execution through it.
- 2026-02-23: Updated `src/goals/BudgetStakeLedger.sol` authorization to permit configured `allocationPipeline` callers.
- 2026-02-23: Removed `src/interfaces/IAllocationCommitHook.sol` and `src/hooks/GoalFlowAllocationLedgerHook.sol`.
- 2026-02-23: Migrated flow/goals tests and harnesses to pipeline configuration.
- 2026-02-23: Updated architecture/reference docs for pipeline terminology and module boundaries.

## Open risks
- ABI surface changed for manager integrations (`setAllocationPipeline` now replaces hook/ledger dual setters).

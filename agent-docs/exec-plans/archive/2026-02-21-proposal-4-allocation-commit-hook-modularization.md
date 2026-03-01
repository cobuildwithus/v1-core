# Proposal 4 - Allocation Commit Hook Modularization

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Decouple allocation-ledger checkpoint orchestration from `CustomFlow` by introducing a modular post-commit hook callback that runs after each successful allocation commit.

## Scope

- In scope:
  - Add a compact allocation commit hook interface.
  - Add configurable hook storage + owner setter/getter on Flow.
  - Implement a goal-ledger hook contract that owns:
    - ledger wiring validation,
    - checkpoint writes,
    - budget-delta detection,
    - child-sync coverage + execution.
  - Rewire `CustomFlow` to invoke the hook (instead of inlining checkpoint orchestration).
  - Preserve externally observable allocation/child-sync behavior.
  - Add/update focused tests for hook wiring + parity.
- Out of scope:
  - `lib/**` changes.
  - Goal/budget economic policy changes.

## Constraints

- Preserve deterministic witness/commit semantics.
- Preserve fail-closed behavior for required child-sync witness coverage.
- Preserve existing child-sync event semantics.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Risks

- Callback ordering regressions around commit -> checkpoint -> child-sync.
- Selector/revert drift in ledger-mode error paths.
- Reentrancy/callback surface growth from external hook invocation.

## Progress Log

- 2026-02-21: Plan created.
- 2026-02-21: Added `src/interfaces/IAllocationCommitHook.sol` and Flow-level hook config surface:
  - `setAllocationHook(address)` / `allocationHook()`,
  - `AllocationHookUpdated` event,
  - `INVALID_ALLOCATION_HOOK` validation error.
- 2026-02-21: Added `src/hooks/GoalFlowAllocationLedgerHook.sol` to own ledger checkpoint callback behavior after commits.
- 2026-02-21: Rewired `src/flows/CustomFlow.sol`:
  - invoke configured allocation hook after successful commit writes,
  - keep goal-ledger validation cache in `CustomFlow`,
  - derive child-sync requirement deltas via `GoalFlowLedgerMode.prepareCheckpointContext(...)`.
- 2026-02-21: Added fail-closed guardrails in `CustomFlow`:
  - non-zero allocation ledger requires non-zero allocation hook,
  - disabling allocation hook while ledger mode is active reverts.
- 2026-02-21: Added shared context helper in `src/library/GoalFlowLedgerMode.sol`:
  - `prepareCheckpointContext(...)` for reusable ledger/weight resolution.
- 2026-02-21: Updated flow/goals test fixtures to explicitly configure `GoalFlowAllocationLedgerHook` where ledger mode is expected.
- 2026-02-21: Updated architecture/reference docs for the new modular allocation-hook boundary.

## Verification

- Targeted hook/module compile (pass):
  - `forge build -q src/Flow.sol src/flows/CustomFlow.sol src/hooks/GoalFlowAllocationLedgerHook.sol src/library/GoalFlowLedgerMode.sol src/interfaces/IFlow.sol src/interfaces/IManagedFlow.sol src/interfaces/IAllocationCommitHook.sol src/storage/FlowStorage.sol`
- Targeted touched-test compile (pass):
  - `forge build -q test/flows/CustomFlowRewardEscrowCheckpoint.t.sol test/flows/FlowBudgetStakeAutoSync.t.sol test/flows/FlowLedgerChildSyncProperties.t.sol test/flows/FlowAllocationsGas.t.sol test/goals/helpers/GoalRevnetFixtureBase.t.sol`
- `forge build -q` (failed due unrelated pre-existing compile errors in goal/TCR modules, including
  `src/goals/BudgetTreasury.sol`, `src/goals/GoalTreasury.sol`, `src/goals/UMASuccessAssertionTreasuryBase.sol`,
  and `src/tcr/BudgetTCRFactory.sol`)
- `pnpm -s test:lite` (failed due existing repo compile blockers, including stack-too-deep in shared flow test helper
  compile path and unresolved pre-existing goal/TCR compile drift)

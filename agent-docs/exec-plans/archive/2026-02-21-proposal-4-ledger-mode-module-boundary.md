# Proposal 4 - Ledger Mode Module Boundary Isolation

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Isolate BudgetStakeLedger-mode orchestration from `CustomFlow` into a dedicated internal module boundary so `CustomFlow` primarily orchestrates allocation, ledger-mode after-allocation hooks, and flow-rate/child-queue updates.

## Scope

- In scope:
  - Add `src/library/GoalFlowLedgerMode.sol` with dedicated helpers for:
    - ledger-mode validation + cache wiring,
    - checkpoint + budget-delta detection,
    - child-sync witness coverage enforcement,
    - best-effort child sync execution.
  - Rewire `src/flows/CustomFlow.sol` to call the new module functions.
  - Keep externally observable behavior and API unchanged.
  - Add/adjust focused flow tests for fail-closed wiring and child-sync coverage parity.
- Out of scope:
  - Interface shape changes for `IFlow`/`ICustomFlow`.
  - Any changes under `lib/**`.
  - Behavioral redesign of budget/goal economics.

## Constraints

- Preserve deterministic revert/error semantics in ledger mode.
- Preserve current child-sync event semantics and best-effort execution behavior.
- Preserve current allocation witness/commit compatibility.
- Required verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- `CustomFlow` no longer inlines most ledger-mode orchestration logic.
- New ledger-mode module compiles and is used by allocation/sync paths.
- Existing ledger mode tests pass; added tests cover module-boundary regressions.
- Baseline verification commands pass.

## Risks

- Refactor touches security-critical cross-contract callbacks and checkpointing.
- Subtle order-of-operations drift could alter required child-sync coverage.
- Error selector/regression mismatch could break consumers/tests.

## Progress Log

- 2026-02-21: Added `src/library/GoalFlowLedgerMode.sol` with:
  - `validateOrRevert` / `validateOrRevertView`,
  - `checkpointAndDetectBudgetDeltas` (calldata + memory variants),
  - `requireChildSyncCoverage`,
  - `executeChildSyncBestEffort`,
  - child target resolution + required-sync preview helpers.
- 2026-02-21: Refactored `src/flows/CustomFlow.sol` ledger-mode paths to call `GoalFlowLedgerMode` and removed inlined ledger-mode orchestration internals.
- 2026-02-21: Added parity regression `test_allocateAndSyncAllocation_withChildSync_matchEventAndLedgerState` in `test/flows/FlowBudgetStakeAutoSync.t.sol`.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass on rerun; 737 passed)
- Additional focused checks (pass):
  - `forge test -q --match-path test/flows/FlowBudgetStakeAutoSync.t.sol`
  - `forge test -q --match-path test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`
  - `forge test -q --match-path test/flows/AllocationWitness.t.sol --match-test testFuzz_decodeAndValidateMemory_commitMatchPasses_commitMismatchReverts`

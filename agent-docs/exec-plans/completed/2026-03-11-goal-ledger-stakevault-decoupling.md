# 2026-03-11 Goal Ledger StakeVault Decoupling

Status: completed
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Remove the last `StakeVault`-specific runtime dependency from `GoalFlowLedgerMode` so the goal-flow ledger substrate stays allocator-neutral.

## Acceptance criteria

- `GoalFlowLedgerMode` no longer caches or validates a stake-vault address.
- Checkpoint gating depends only on `IGoalTreasury.resolved()` and goal-scoped strategy validation.
- Goal-ledger init validation still permits the pre-treasury-init bootstrap path and still fail-closes on wrong flow wiring.
- Child-sync behavior and allocator-weight validation remain unchanged for both `StakeVault` and `SingleAllocatorStrategy`.
- Targeted flow/ledger tests cover the decoupled behavior, including treasury-resolved short-circuit and the inconsistent `stakeVault.goalResolved()` mock case no longer suppressing checkpoints.

## Scope

- In scope:
  - `src/library/GoalFlowLedgerMode.sol`
  - `test/harness/GoalFlowLedgerModeHarness.sol`
  - `test/flows/GoalFlowLedgerModeValidation.t.sol`
  - `test/flows/GoalFlowLedgerModeBranchCoverage.t.sol`
  - `test/flows/FlowLedgerChildSyncProperties.t.sol`
  - focused allocator-neutral docs if the boundary description changes materially
- Out of scope:
  - `StakeVault` terminal-side-effect behavior
  - treasury finalization semantics
  - factory/preset wiring outside existing ledger-mode tests

## Constraints

- Keep neutral substrate code free of `IStakeVault` runtime reads.
- Preserve fail-closed behavior for invalid ledgers, wrong goal treasury wiring, wrong flow wiring, and strategy/account-resolution mismatches.
- Do not introduce managed/open runtime branching.
- Avoid touching active managed-preset implementation files owned by other ledger rows unless compile fallout forces it.

## Tasks

1. Narrow `GoalFlowLedgerMode` validation/cache structs and helper return types to allocator-neutral goal-treasury context.
2. Replace stake-vault checkpoint suppression with treasury-only resolved checks.
3. Update harness and targeted tests to assert the new substrate boundary.
4. Run required verification plus mandatory simplify, coverage-audit, and completion-review passes.

## Decisions

- `GoalTreasury.resolved()` is the canonical neutral terminal signal for ledger-mode checkpoint suppression.
- `StakeVault.goalResolved()` remains a treasury side-effect / withdrawal-preparation concern, not a flow-substrate validation input.

## Verification plan

- Focused Forge tests for `GoalFlowLedgerMode` and flow ledger child-sync properties.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

## Outcome

- `GoalFlowLedgerMode` now validates allocator-neutral ledger context through goal-treasury/flow ownership only and suppresses checkpoints only when `IGoalTreasury.resolved()` is true.
- Added targeted regressions for init-path wrong-flow rejection, managed treasury-resolved suppression, and stale stake-vault terminal-state non-suppression.
- `forge build -q src/library/GoalFlowLedgerMode.sol src/hooks/GoalFlowAllocationLedgerPipeline.sol test/harness/GoalFlowLedgerModeHarness.sol test/flows/GoalFlowLedgerModeValidation.t.sol test/flows/GoalFlowLedgerModeBranchCoverage.t.sol test/flows/FlowLedgerChildSyncProperties.t.sol` passed.
- `pnpm -s lint:solidity:warnings` passed.
- `pnpm -s verify:required` failed outside this scope on `test/goals/ManagedBudgetController.t.sol:ManagedBudgetControllerRealStackTest::test_removeBudget_realStackFailClosesActivatedBudgetAndKeepsSyncTerminal` with `SF_TOKEN_MOVE_INSUFFICIENT_BALANCE()` while the directly affected flow/ledger suites passed.

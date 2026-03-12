# 2026-03-12 Goal Factory Default Policy Wiring

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Make `GoalFactory` use its stored default goal/budget spend policies when deploy callers omit explicit policy addresses.
- Harden `SingleAllocatorStrategy` so the allocator matches its documented controller-contract assumption.

## Scope

- In scope:
  - `src/goals/GoalFactory.sol`
  - `src/allocation-strategies/SingleAllocatorStrategy.sol`
  - focused GoalFactory spend-policy and strategy regression tests
- Out of scope:
  - changing already-shrunk managed deployer prep API
  - changing open/managed spend-policy semantics when callers provide explicit policy addresses
  - docs unless behavior wording clearly becomes misleading

## Constraints

- Layer on top of the active managed-preset baggage-trim work without reverting those edits.
- Preserve current explicit-policy behavior for nonzero inputs.
- Keep the defaulting logic fail-fast for non-contract explicit policy addresses.

## Intended change

1. Resolve `goalSpendPolicy` and `budgetSpendPolicy` inside `GoalFactory._deployGoal(...)`, defaulting zero inputs to `DEFAULT_GOAL_SPEND_POLICY` / `DEFAULT_BUDGET_SPEND_POLICY`.
2. Thread the resolved policy addresses through core-stack finalization, open BudgetTCR deployment, and managed controller initialization.
3. Require `allocator_.code.length > 0` in `SingleAllocatorStrategy._initialize(...)`.
4. Update focused tests to cover default-policy fallback and contract-only allocator hardening.

## Verification

- `forge test --match-path test/flows/SingleAllocatorStrategy.t.sol` ✅
- `forge test --match-path test/goals/GoalFactorySpendPolicyDeploy.t.sol` ✅
- `forge test --match-path test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol` ✅
- `forge test --match-path test/flows/FlowLedgerChildSyncProperties.t.sol` ❌ existing unrelated failure in `testFuzz_allocate_stakeVaultResolved_childCommitNonZero_changedStake_stillCheckpointsAndSyncs`
- `pnpm -s lint:solidity:warnings` ✅
- `pnpm -s verify:required` ❌ same existing unrelated `FlowLedgerChildSyncProperties` fuzz failure on both runs
- completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review` ✅

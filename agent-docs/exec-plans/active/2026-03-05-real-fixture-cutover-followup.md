# 2026-03-05 Real Fixture Cutover Follow-up

## Goal

Replace the two highest-value remaining mock-heavy success-path suites with real local contract fixtures:

- `test/BudgetTCR.t.sol`
- `test/goals/UnderwritingIntegration.t.sol`

Success means the main lifecycle/assertion paths in those suites no longer depend on synthetic mock treasuries/flows for happy-path behavior where equivalent production-local contracts already exist in-repo.

## Scope

- Test-only Solidity changes.
- No `src/**` behavior changes unless a compile-preserving test-only hook is impossible.
- Cobuild-related suites remain out of scope.

## Constraints

- Preserve existing explicit failure-injection coverage (`vm.mockCallRevert`, hostile harnesses) where that is the point of the test.
- Do not touch files owned by other active coordination-ledger entries.
- Parent agent owns verification; spawned subagents must not run repo-wide verification.

## Initial Approach

1. Audit `BudgetTCR.t.sol` for the smallest realistic fixture cutover that replaces `MockBudgetTCRSystem` success-path dependencies with real `CustomFlow` / `GoalTreasury` / `BudgetStakeLedger` / `BudgetTreasury` wiring where feasible.
2. Audit `UnderwritingIntegration.t.sol` for the largest remaining mock-driven lifecycle blocks and replace them with real `BudgetStakeLedger`, `BudgetTreasury`, `GoalTreasury`, `StakeVault`, and `PremiumEscrow` composition where feasible.
3. Keep targeted hostile-branch tests mocked/harnessed instead of forcing fully real external systems into negative-path checks.

## Verification Plan

- Required gate: `pnpm -s verify:required`
- Warning gate: `pnpm -s lint:solidity:warnings`
- Targeted suites during iteration as needed for the two touched files.
- Completion workflow subagents: `simplify` -> `test-coverage-audit` -> `task-finish-review`

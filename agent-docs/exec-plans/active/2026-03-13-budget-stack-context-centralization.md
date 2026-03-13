# Budget Stack Context Centralization

Status: completed
Created: 2026-03-13
Updated: 2026-03-13

## Goal

Reduce drift risk between open and managed budget-stack deployment by centralizing `PreparedBudgetStackContext` construction and collapsing the duplicated risk/no-risk instantiation flow to one shared body plus the single varying treasury deployer call.

## Scope

- In scope:
  - `src/goals/library/BudgetStackInstantiationLib.sol`
  - `src/tcr/library/BudgetTCRStackActions.sol`
  - `src/goals/ManagedBudgetController.sol`
  - focused regression coverage if the refactor exposes a missing guard
- Out of scope:
  - changing open vs managed preset behavior
  - changing stack validation semantics beyond what the simplification requires
  - changing deployer interfaces or budget-treasury initializer fields

## Constraints

- Preserve open-preset optional premium/risk-module behavior and managed-preset no-risk behavior exactly.
- Keep prepared-stack validation and controller-owned topology recording unchanged.
- Preserve current dirty worktree state and do not revert unrelated edits.
- Finish with required Solidity verification, size check, completion workflow passes, and a scoped commit.

## Acceptance Criteria

- Managed and open call sites share one context-construction helper instead of hand-building parallel nested structs.
- Instantiation library uses one common deployment/finalization body and keeps the risk/no-risk difference isolated to the treasury deployer call plus required premium-presence guards.
- No runtime config or lifecycle field is duplicated across controller/TCR call sites after the refactor.
- Required checks and completion workflow pass, or any unrelated failure is explicitly justified.

## Risks

- Refactoring the instantiation seam can accidentally change premium-escrow hookup order or child-flow registration timing.
- Helper extraction must not weaken the explicit fail-closed checks for prepared premium-module presence/absence.

## Progress Log

- 2026-03-13: Added an active coordination-ledger row and created the execution plan.
- 2026-03-13: Centralized prepared budget-stack context construction in `BudgetStackInstantiationLib`, rewired open/managed callers to use the shared builder, and collapsed the risk/no-risk instantiation helpers into one shared path that selects the treasury deployer call from prepared premium-module state.
- 2026-03-13: Simplify pass removed redundant local `allocationMechanism` duplication in `BudgetTCRStackActions` and tightened the shared instantiation helper without changing behavior.
- 2026-03-13: Verification summary:
  - pass: `forge build -q --skip test --skip script src/goals/library/BudgetStackInstantiationLib.sol src/tcr/library/BudgetTCRStackActions.sol src/goals/ManagedBudgetController.sol`
  - pass: `pnpm -s verify:required` (pre-simplify stale pass on earlier tree state)
  - pass: `pnpm -s lint:solidity:warnings`
  - pass: `pnpm -s build:sizes`
  - pass: `forge test --match-path test/goals/ManagedBudgetController.t.sol --match-test test_createBudget_realStackDeploysBudgetTreasuryAndScopedChildFlow`
  - pass: `forge test --match-path test/BudgetTCR.t.sol --match-test test_activateRegisteredBudget_persistsListingAndRuntimeConfigOnBudgetTreasury`
  - fail unrelated: fresh `pnpm -s verify:required` rerun failed only in `test/mocks/FakeUMATreasurySuccessResolver.t.sol:DeployGoalFactoryScriptWiringTest` with `vm.isFile: the path  is not allowed to be accessed for read operations`, which sits on the active GoalFactory/script lane and is outside this budget-stack refactor scope.

# Budget Topology Reader Dedupe

Status: completed
Created: 2026-03-13
Updated: 2026-03-13

## Goal

Move the shared budget-topology read logic behind one library surface so `BudgetTCR` and `ManagedBudgetController` no longer duplicate reverse-index validation and topology projection behavior.

## Scope

- In scope:
  - `src/goals/library/BudgetTopologyRegistryLib.sol`
  - `src/tcr/BudgetTCR.sol`
  - `src/goals/ManagedBudgetController.sol`
  - targeted topology regressions only if the shared helper shape needs direct coverage
- Out of scope:
  - budget activation/removal semantics
  - stack deployment behavior
  - unrelated dirty worktree cleanup

## Constraints

- Preserve current open and managed controller behavior exactly, including stale reverse-index rejection and inactive-topology discoverability.
- Respect the pre-existing dirty edit in `ManagedBudgetController.sol`.
- Keep this as a read-surface-only simplification unless verification or completion audit proves a gap.

## Verification

- Required:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `pnpm -s build:sizes`
- Completion workflow:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

## Progress Log

- 2026-03-13: Plan created and coordination ledger claimed for the shared topology-reader dedupe.
- 2026-03-13: Added `BudgetTopologyReaderBase` so `BudgetTCR` and `ManagedBudgetController` share one public topology/item-id read implementation while keeping controller-specific active-state hooks.
- 2026-03-13: Focused topology regressions passed for open and managed controllers via `forge test --match-path test/BudgetTCR.t.sol --match-test 'test_(activateRegisteredBudget_exposesCanonicalTopologyAndReverseLookups|budgetControllerTopology_readsAllowZeroMechanismModules|budgetControllerTopology_readsIgnoreStaleReverseIndexes|finalizeRemovedBudget_keepsTopologyDiscoverableButInactive)'` and `forge test --match-path test/goals/ManagedBudgetController.t.sol --match-test 'test_(createBudget_realStackDeploysBudgetTreasuryAndScopedChildFlow|removeBudget_keepsTopologyDiscoverableAndCompactsActiveSetForLiveBudget|removeBudget_preActivation_usesRemovalFinalizer_andSyncsGoal)'`.
- 2026-03-13: Completion workflow finished with clean simplify/coverage/review passes (no additional changes required) and green repo gates: `pnpm -s verify:required`, `pnpm -s lint:solidity:warnings`, and `pnpm -s build:sizes`.

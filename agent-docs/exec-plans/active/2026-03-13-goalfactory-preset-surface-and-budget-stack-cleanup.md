# GoalFactory Preset Surface And Budget Stack Cleanup (2026-03-13)

## Goal

Finish the preset split so the public factory API, shared budget-stack deployer ownership, helper naming, and shared scaffolding all read as "shared substrate, two control planes" without open-preset leakage into managed paths.

## Scope

- Replace `GoalFactory.DeployParams` with preset-specific entrypoints and param structs.
- Expose managed gate-policy wiring through the managed deploy path.
- Rename and move the shared stack deployer out of `src/tcr/**`, thread its implementation directly into `GoalFactory`, and remove TCR-only alias interfaces plus dead `budgetTCR()` view.
- Rename/move generic helper libraries out of TCR-specific names.
- Share budget topology/indexing and prepared-stack instantiation scaffolding without merging open and managed controller lifecycles.
- Centralize canonical open/managed stack-module tuples and remove unused `ChildFlowStrategyMode.Fixed`.
- Update tests, scripts, and architecture docs for the new surface.

## Constraints

- Preserve the current open and managed runtime control-plane semantics.
- Keep runtime instances clone-based; do not introduce fresh constructor deployment paths for repeatable runtime modules.
- Do not reintroduce hidden managed dependencies on `BudgetTCRFactory`.
- Leave unrelated dirty deploy artifact edits untouched unless verification explicitly regenerates them.

## Design Summary

- Public factory surface becomes preset-specific:
  - `deployOpenGoal(...)`
  - `deployManagedGoal(...)`
  - `deployOpenGoalForCommunity(...)`
  - `deployManagedGoalForCommunity(...)`
- Shared goal inputs move into a common struct plus shared budget-runtime config; open-only TCR market config is isolated from managed params.
- Managed preset wiring passes an explicit `managedBudgetGatePolicy` through to `ManagedBudgetController.initialize(...)`.
- Shared deployer implementation becomes `BudgetStackDeployer` under a neutral path, and `GoalFactory` receives its implementation directly as an immutable constructor dependency.
- Generic helper naming is normalized (`BudgetTerminalActions`, `BudgetGateSync`, `StakeCoverageGateActions`) and both controllers use the shared gate helper/event semantics.
- Shared topology lookup/index storage and prepared-stack instantiation move into neutral helper libraries; open-only lifecycle logic remains in `BudgetTCR`, managed-only lifecycle logic remains in `ManagedBudgetController`.
- Canonical open/managed `StackModuleConfig` tuples live in one shared library.

## Verification Plan

- Update/refactor targeted Foundry tests covering:
  - GoalFactory open vs managed deploy surfaces
  - managed gate-policy wiring
  - shared budget-stack deployer rename/surface
  - stack-module preset config and removed fixed mode
  - helper/event naming regressions where assertions depend on event signatures
- Required Solidity gate: `pnpm -s verify:required`
- Solidity warning baseline gate: `pnpm -s lint:solidity:warnings`
- Solidity size gate: `pnpm -s build:sizes`
- Mandatory completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Final Status

- Completed the preset-specific factory API split, neutral stack deployer rename/cutover, managed gate-policy threading, generic helper renames, shared topology/instantiation scaffolding extraction, preset tuple centralization, and `ChildFlowStrategyMode.Fixed` removal.
- Simplify pass follow-ups applied:
  - removed managed deploy adapter noise in `GoalFactory`
  - made `BudgetStackInstantiationLib` the single premium-escrow validation point
  - aligned test preset helpers with `BudgetStackPresetConfigLib`
- Coverage pass added GoalFactory tests for:
  - direct `BUDGET_STACK_DEPLOYER_IMPL` wiring and non-contract constructor rejection
  - managed community deploy funding-context override while preserving managed gate policy
  - permissionless managed community deploy authority preservation
- Final verification on the post-review tree:
  - `pnpm -s verify:required` passed
  - `pnpm -s lint:solidity:warnings` passed
  - `pnpm -s build:sizes` passed (`BudgetTCR` runtime 24,033 bytes; +543 margin)
- Completion workflow review (`task-finish-review`) returned no findings; residual risk is limited to future end-to-end deployment-script dry-run coverage.

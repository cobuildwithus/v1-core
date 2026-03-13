# GoalFactory Managed Impl Cutover (2026-03-13)

## Goal

Remove constructor-time managed preset subdeployments from the canonical `GoalFactory` deployment path so Base deployment stays within initcode limits while preserving existing clone-based managed runtime behavior.

## Scope

- Update `GoalFactory` to accept predeployed managed implementation addresses.
- Update `DeployGoalFactoryImplementations` to predeploy and record those managed implementation contracts.
- Update `DeployGoalFactory` / `GoalFactoryPairDeployer` to pass through the new implementation addresses.
- Update direct constructor-based tests and deployment-script wiring assertions.
- Refresh deployment architecture notes for the new canonical path.

## Constraints

- Preserve the existing managed preset runtime semantics and immutables exposed by `GoalFactory`.
- Do not reintroduce repeatable `new SomeContract(...)` deployment paths for runtime instances.
- Keep implementation contracts predeployed once and reused via the existing clone/factory topology.
- Leave unrelated dirty deploy artifacts alone unless a verification flow intentionally regenerates them.

## Design Summary

- Predeploy `ManagedBudgetController`, zero-config `SingleAllocatorStrategy`, zero-config `BudgetSingleAllocatorStrategy`, and `BudgetSingleAllocatorStrategyFactory` during the implementations deployment script.
- Thread those addresses through the deploy script config structs into `GoalFactory`.
- Replace constructor-time subdeployments in `GoalFactory` with address validation plus immutable assignment.
- Update script artifact outputs/TOML keys and constructor-based tests to supply the managed implementation addresses explicitly.

## Verification Plan

- Targeted Foundry tests for GoalFactory/script wiring regressions.
- Required Solidity gate: `pnpm -s verify:required`.
- Solidity warning baseline gate: `pnpm -s lint:solidity:warnings`.
- Solidity size gate: `pnpm -s build:sizes`.
- Mandatory completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`.

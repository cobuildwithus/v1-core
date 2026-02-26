# GoalFactory Deployment Stack Plan (2026-02-26)

## Goal

Implement a production `GoalFactory` that deploys and initializes the full goal stack in one transaction, plus Foundry scripts to deploy factory dependencies and deploy a goal from the factory.

## Scope

- Add `src/goals/GoalFactory.sol`.
- Add canonical external interface `src/interfaces/external/revnet/IREVDeployer.sol`.
- Add Foundry scripts:
  - `script/DeployGoalFactory.s.sol`
  - `script/DeployGoalFromFactory.s.sol`

## Key constraints

- Preserve atomic initialization guardrails for initializer-based contracts.
- Do not modify `lib/**`.
- Use deterministic BudgetTCR address prediction path already present in `BudgetTCRFactory`.
- Keep naming exactly `GoalFactory` (no permissionless prefix).

## Design summary

- Predict `budgetTCR` address from `BudgetTCRFactory.predictBudgetTCRAddress(...)` before flow initialization.
- Initialize `CustomFlow` with predicted `budgetTCR` as `recipientAdmin`, then deploy/init TCR stack via factory.
- Keep all contracts wired and initialized in the same tx from `GoalFactory.deployGoal(...)`.
- Add deploy scripts to:
  - deploy reusable implementations and core factories.
  - deploy a goal by passing configurable env params.

## Verification plan

- Run targeted Foundry compile/tests for new files.
- Run required gate: `pnpm -s verify:required`.
- Run mandatory completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`.
- Re-run required gate after any post-audit edits.

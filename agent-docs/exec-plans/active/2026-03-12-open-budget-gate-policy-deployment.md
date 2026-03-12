# Open Budget Gate Policy Deployment

## Goal

Reduce `BudgetTCR` runtime size by removing the in-contract default `StakeCoverageGatePolicy` deployment path and instead injecting a shared deployed gate-policy address from the implementation deployment artifacts through `GoalFactory`.

## Constraints / Assumptions

- Preserve current open-preset runtime behavior: default gate policy should remain `StakeCoverageGatePolicy`.
- Managed preset gate-policy wiring stays unchanged.
- Deployment scripts must continue to produce complete implementation artifacts for downstream factory deployment.

## Files / Scope

- `src/tcr/BudgetTCR.sol`
- `src/tcr/library/BudgetTCRInitValidation.sol`
- `src/tcr/library/BudgetTCRGateSync.sol`
- `src/goals/GoalFactory.sol`
- `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`
- `script/DeployGoalFactoryImplementations.s.sol`
- `script/DeployGoalFactory.s.sol`
- affected tests / deployment-script tests

## Plan

1. Deploy a shared `StakeCoverageGatePolicy` in `DeployGoalFactoryImplementations` and export it in text/TOML artifacts.
2. Thread that address through `DeployGoalFactory` and `GoalFactory` as an immutable open-preset dependency.
3. Update open-preset `BudgetTCR` wiring to require a nonzero gate-policy address instead of self-deploying one.
4. If needed, move init-time open-preset validation into a linked external library so the `initialize` runtime path no longer inflates `BudgetTCR`.
5. If still needed, move `BudgetTCR` gate evaluation/failure emission into a BudgetTCR-only linked helper instead of touching shared managed-controller dependencies.
6. Update tests for the new required gate-policy input and verify contract-size improvement.

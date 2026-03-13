# Deploy Validation Hardening (2026-03-13)

## Goal

Fail goal and budget deployments early when required spend-policy or success-resolver dependencies do not satisfy the runtime interface shape that the treasury paths already depend on.

## Scope

- Validate managed `budgetSpendPolicy` at controller initialization using the same spend-policy probe used by treasury initialization.
- Add a shared success-resolver validation library that probes the UMA config surface required by runtime success resolution.
- Apply success-resolver validation at goal deploy/init and budget controller/init entrypoints that currently only check nonzero or code length.
- Add regression tests for bad managed spend-policy config and malformed success resolver config on goal and budget deployment paths.
- Normalize open `BudgetTCR` test fixtures to use a valid success-resolver config now that open-stack init also validates resolver shape.

## Constraints

- Preserve the existing shared/open/managed architecture split and fail-closed runtime semantics.
- Do not add compatibility shims or low-level selector fallbacks for required trusted-core dependencies.
- Keep the validation source of truth shared and composable rather than duplicating probe logic across factories/controllers/treasuries.
- Leave unrelated dirty deploy/doc artifacts untouched.

## Design Summary

- Reuse `SpendPolicyValidationLib.passesValidationProbe(...)` at managed controller initialization so invalid managed budget spend policies cannot be stored and later brick budget creation.
- Introduce `SuccessResolverValidationLib` that probes `optimisticOracle()` and `assertionCurrency()` on `IUMATreasurySuccessResolverConfig`.
- Use that success-resolver validation in:
  - `GoalFactory` for root goal and budget runtime inputs
  - `ManagedBudgetController.initialize(...)`
  - `BudgetTCRInitValidation.validateInitialization(...)`
- Keep runtime success resolution unchanged; deployment-time validation should align with the runtime dependency shape.

## Verification Plan

- Add targeted Foundry regressions for invalid managed spend policy and malformed success resolvers.
- Required Solidity gate: `pnpm -s verify:required`
- Solidity warning baseline gate: `pnpm -s lint:solidity:warnings`
- Solidity size gate: `pnpm -s build:sizes`
- Mandatory completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
Status: completed
Updated: 2026-03-13
Completed: 2026-03-13

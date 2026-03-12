# 2026-03-12 No Premium Gate Validation

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Prevent zero-slash and explicit no-premium budget deployments from self-disabling budgets through the shipped stake-coverage gate.
- Catch incompatible gate-policy wiring at initialization time for both open and managed controllers.
- Preserve a built-in no-gate path for configurations that intentionally have no coverage-based gating.

## Scope

- In scope:
  - `src/goals/policies/library/BudgetGatePolicyHook.sol`
  - `src/tcr/library/BudgetTCRInitValidation.sol`
  - `src/tcr/BudgetTCR.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/interfaces/IBudgetTCR.sol`
  - `src/goals/ManagedBudgetController.sol`
  - `src/interfaces/IManagedBudgetController.sol`
  - `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`
  - targeted regression tests for open no-premium / zero-slash wiring and managed controller gate validation
  - deployer/init mismatch regressions for premium-module presence invariants
  - `test/BudgetTCRFactory.t.sol` alignment for explicit no-premium deployments
- Out of scope:
  - new gate-policy contract deployments or constructor wiring changes
  - redesigning premium escrow or underwriter slash economics
  - changing managed preset runtime behavior beyond rejecting incompatible optional gate policies

## Constraints

- Keep open-preset coverage gating intact when `budgetSlashPpm != 0`.
- Treat `address(0)` as the built-in no-op gate only where zero credit coverage makes gating optional.
- Avoid broad churn in `test/goals/ManagedBudgetController.t.sol` because another active task also owns that file.
- Preserve current stack-deployer explicit no-premium mode semantics when both premium and slash rates are zero.

## Intended Change

1. Add an explicit zero-coverage compatibility probe in `BudgetGatePolicyHook`.
2. Update `BudgetTCR` init validation to:
   - allow `budgetGatePolicy == address(0)` when `budgetSlashPpm == 0`,
   - reject nonzero gate policies that disable zero-coverage contexts when `budgetSlashPpm == 0`,
   - keep normal contract/interface validation for positive-slash coverage-gated configs.
3. Skip runtime gate application in `BudgetTCR.syncBudgetTreasuries(...)` when no gate policy is configured.
4. Update `ManagedBudgetController.initialize(...)` to reject optional gate policies that are incompatible with its always-zero coverage inputs.
5. Make the GoalFactory open-preset budget-TCR deploy helper resolve to no gate for zero-slash configs, and to explicit no-premium risk wiring when both premium and slash are zero.
6. Add regression tests for the new accepted and rejected configurations.
7. Reject stack deployers that advertise `PremiumEscrowMode.None` without the zero-rate guard, and reject `BudgetTCR.initialize(...)` configs whose premium presence expectations disagree with the actual stack deployer module config.

## Verification

- completion workflow completed with a local fallback for the audit steps:
  - simplify pass applied one behavior-preserving cleanup by encapsulating the `stackModuleConfig()` lookup inside `BudgetTCRInitValidation.validateStackModuleCompatibility(...)`
  - the coverage-audit subagent was blocked by a workspace mismatch, so regression coverage was assessed locally instead
  - local finish review found no additional scoped issues
- targeted forge tests passed:
  - `forge test --match-path test/BudgetTCR.t.sol`
- `pnpm -s verify:required` passed
- `pnpm -s lint:solidity:warnings` passed
- `pnpm -s build:sizes` passed
- `bash scripts/check-agent-docs-drift.sh` passed
- `bash scripts/doc-gardening.sh --fail-on-issues` passed
- `git diff --check` passed
Completed: 2026-03-12

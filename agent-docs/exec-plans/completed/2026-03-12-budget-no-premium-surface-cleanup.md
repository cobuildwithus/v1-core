# 2026-03-12 Budget No Premium Surface Cleanup

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Finish the optional-premium cut so "no premium module" is first-class all the way down the deployer surface, without dead args, placeholder risk wiring, or a legacy open-only initializer branch.

## Scope

- In scope:
  - `src/interfaces/IBudgetStackDeployer.sol`
  - `src/tcr/interfaces/IBudgetTCRDeployer.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/BudgetTCRFactory.sol`
  - `src/tcr/library/BudgetTCRInitValidation.sol`
  - `src/tcr/library/BudgetTCRStackDeploymentLib.sol`
  - `src/tcr/library/BudgetTCRStackActions.sol`
  - `src/goals/ManagedBudgetController.sol`
  - targeted test/mocks that cover deployer initialization, managed controller deployment, and factory/init validation
- Out of scope:
  - removing the goal-level `UnderwriterSlasherRouter` deployment from the core goal stack
  - changing real `PremiumEscrow` runtime accounting or slash behavior
  - broad cleanup outside the no-premium deployer/factory seam

## Constraints

- Preserve explicit fail-fast behavior whenever premium/slash rates are nonzero.
- Keep "no premium module" represented by real absence (`address(0)` / `PremiumEscrowMode.None`), not by dummy addresses or placeholder structs.
- Do not widen into unrelated dirty worktree edits.

## Intended Change

1. Remove the dead `underwriterSlasherRouter` parameter from `prepareBudgetStack(...)` and update every caller/mock.
2. Make budget treasury deployment mode-aware by separating plain treasury init from premium-risk-module init so managed/no-premium callers stop passing dummy `RiskModuleInitConfig`.
3. Canonicalize zero-rate premium configuration at the lower layer by rejecting or normalizing `budgetPremiumPpm == 0 && budgetSlashPpm == 0` when a live premium module/router is still supplied.
4. Collapse the open preset onto `initializeWithConfig(...)` so `BudgetTCRDeployer` exposes one initialization path.
5. Update targeted tests to lock the new explicit-absence behavior and API surface.

## Verification

- targeted forge tests for deployer/factory/managed-controller coverage
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s build:sizes`
- completion workflow:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

## Outcome

- `IBudgetStackDeployer` no longer carries the dead `underwriterSlasherRouter` input on `prepareBudgetStack(...)`, and treasury deployment is split into plain vs risk-module entrypoints.
- `BudgetTCRDeployer` now exposes only `initializeWithConfig(...)`, while `BudgetTCRFactory` canonicalizes zero-rate premium configs to explicit no-premium mode before deployer initialization.
- Managed budgets now stay explicitly no-premium: `ManagedBudgetController.createBudget(...)` rejects any prepared stack that returns a live premium escrow instead of partially wiring premium state.
- Targeted regressions now cover the new deployer API, zero-rate canonicalization with stale invalid premium/router inputs, and the managed-controller fail-closed premium-escrow rejection.
- Completion workflow finished cleanly:
  - `simplify`: hoisted the repeated managed-controller ledger lookup and extracted the shared open-preset deployer helper in `BudgetTCRDeployments.t.sol`
  - `test-coverage-audit`: added factory regression coverage for zero-rate canonicalization when stale invalid premium/router wiring is supplied
  - `task-finish-review`: initially found a managed-controller premium wiring hole; the controller now fails closed and the rerun returned no findings
- Final verification passed:
  - `forge test --match-contract ManagedBudgetControllerTest`
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `pnpm -s build:sizes`

## Open questions

- None. A residual architectural note remains that `ManagedBudgetController` still rejects incompatible stack deployers lazily on first `createBudget(...)` instead of proving compatibility at `initialize(...)` time.

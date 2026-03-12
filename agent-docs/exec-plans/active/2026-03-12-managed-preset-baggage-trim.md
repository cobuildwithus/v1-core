# 2026-03-12 Managed Preset Baggage Trim

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Remove managed-preset init requirements that only exist to mirror the open underwriting path.

## Scope

- In scope:
  - `src/goals/ManagedBudgetController.sol`
  - `src/goals/ManagedBudgetControllerStackDeployer.sol`
  - `src/goals/NullPremiumEscrow.sol`
  - `src/tcr/library/BudgetTCRStackDeploymentLib.sol`
  - `src/goals/GoalFactory.sol`
  - managed-focused regression tests
  - architecture/reference docs that describe managed premium wiring
- Out of scope:
  - removing the shared core-stack deployment of `BudgetStakeLedger` or `UnderwriterSlasherRouter`
  - changing open-preset `PremiumEscrow` semantics
  - renaming `premiumEscrow` ABI/surfaces

## Constraints

- Keep `IPremiumEscrow.initialize(...)` shape stable for open/managed symmetry.
- Managed factory wiring should no longer require a real `budgetAllocationLedger` or `underwriterSlasherRouter` to initialize the controller.
- Open-preset deployment and `PremiumEscrow` fail-fast behavior must stay intact.

## Intended change

1. `ManagedBudgetController.initialize(...)` allows zero `budgetAllocationLedger` and zero `underwriterSlasherRouter`, while still validating nonzero values as contracts.
2. Managed factory wiring initializes the controller with zero ledger/router addresses by default.
3. `ManagedBudgetControllerStackDeployer` stops treating `budgetAllocationLedger` as a required managed-stack prep dependency.
4. `BudgetTCRStackDeploymentLib` stops blanket-requiring `budgetStakeLedger` and `underwriterSlasherRouter`; the concrete escrow implementation decides whether those inputs are mandatory.
5. `NullPremiumEscrow.initialize(...)` keeps only the identity/seam values it semantically uses and ignores managed-unused ledger/router args.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Outcome

- `ManagedBudgetController.initialize(...)` now allows zero `budgetAllocationLedger` and zero `underwriterSlasherRouter` while still validating nonzero addresses as contracts.
- Managed factory/controller wiring zeroes those controller dependencies by default.
- `NullPremiumEscrow.initialize(...)` now only requires the `budgetTreasury`/`goalFlow` seam values it actually uses and ignores managed-unused ledger/router/slash inputs.
- Shared stack deployment validation now leaves ledger/router mandatory-ness to the concrete premium-escrow implementation so open `PremiumEscrow` stays fail-fast while managed `NullPremiumEscrow` stays minimal.
- Focused managed-stack regression tests passed; `pnpm -s lint:solidity:warnings` passed; `pnpm -s verify:required` remains blocked by the unrelated `FlowLedgerChildSyncProperties` failure already present in the active tree.

## Open questions

- None at plan open. The managed preset still deploys shared core stake-ledger/router modules upstream; this pass only removes controller/null-escrow dependence on them.

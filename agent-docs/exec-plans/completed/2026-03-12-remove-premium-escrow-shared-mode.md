# 2026-03-12 Remove Premium Escrow Shared Mode

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Remove the unsupported `IBudgetStackDeployer.PremiumEscrowMode.Shared` cutover path so the deployer surface no longer advertises reuse of a single premium escrow across multiple budgets.

## Scope

- In scope:
  - `src/interfaces/IBudgetStackDeployer.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - targeted deployer/managed regression tests that still configure `PremiumEscrowMode.Shared`
  - narrow docs updates only if the public architecture/contracts docs still describe shared premium escrows after the code change
- Out of scope:
  - redesigning `IPremiumEscrow` for future multi-budget implementations
  - changing `PremiumEscrow` accounting, claim, slash, or close semantics
  - reopening the broader no-premium / zero-slash cutover beyond fallout strictly required by this enum removal

## Constraints

- Keep the open preset on `PremiumEscrowMode.Clone`.
- Keep the explicit no-premium path on `PremiumEscrowMode.None`.
- Do not touch files currently owned by other active ledger entries unless the change becomes unavoidable.
- Treat this as a hard cutover: no backward-compatibility shim for `Shared`.

## Planned Changes

1. Delete `Shared` from `IBudgetStackDeployer.PremiumEscrowMode`.
2. Remove the `Shared` branch from `BudgetTCRDeployer._preparePremiumEscrow()`.
3. Update remaining tests to use `None` or `Clone` according to the behavior they actually validate.
4. Update docs only where they would otherwise misstate the runtime deploy surface.

## Verification

- Targeted budget/deployer tests while iterating
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s build:sizes`
- completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Risks To Watch

- Enum ordinal changes can break tests or deployment helpers that still assume the old ordering.
- Managed-stack tests that used `Shared` as shorthand for reusing `NullPremiumEscrow` need to prove the same behavior through `None` or `Clone` instead of a stale enum branch.
Completed: 2026-03-12

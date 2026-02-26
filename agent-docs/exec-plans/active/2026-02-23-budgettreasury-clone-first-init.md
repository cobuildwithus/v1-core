# BudgetTreasury Clone-First Initialize Flow

Status: in_progress
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Eliminate nonce-based predicted treasury address coupling by adopting a clone-first budget treasury flow:
- create a budget treasury clone during stack preparation,
- deploy stake vault anchored to the real clone address,
- initialize the clone after child flow deployment.

## Scope

- In scope:
  - `BudgetTreasury` constructor-to-initialize migration for clone deployment.
  - `BudgetTCRDeployer` removal of nonce prediction/tracking and clone-first prepare path.
  - `BudgetTCRDeployments` deploy helper conversion from constructor deployment to clone initialization.
  - Tests and architecture docs updates for clone-first semantics.
- Out of scope:
  - Changes under `lib/**`.
  - Deterministic `CREATE2`/`CREATE3` addressing.
  - Non-budget treasury architecture changes.

## Constraints

- Preserve current budget lifecycle behavior and access-control invariants.
- Keep stake-vault ↔ treasury binding fail-closed (`STAKE_VAULT_BUDGET_MISMATCH`).
- Maintain existing BudgetTCR activation sequence (`prepare -> add child flow -> deploy/init treasury`).
- Required verification gate: `pnpm -s verify:required`.

## Acceptance criteria

- `BudgetTCRDeployer` no longer stores/uses create nonce prediction state.
- Treasury address used by `GoalStakeVault` is a real deployed clone address from prepare time.
- `deployBudgetTreasury` initializes the pre-created treasury clone and returns that address.
- Tests covering budget stack preparation/deployment pass without nonce prediction assumptions.
- Architecture docs describe clone-first setup instead of predicted-address setup.

## Progress log

- 2026-02-23: Migrated `BudgetTreasury` to initializer-based deployment (`constructor` disables initializers).
- 2026-02-23: Refactored `BudgetTCRDeployer` to clone treasury in `prepareBudgetStack` and removed nonce prediction state/checks.
- 2026-02-23: Refactored `BudgetTCRDeployments.deployBudgetTreasury` to initialize pre-created treasury anchor from `GoalStakeVault.goalTreasury()`.
- 2026-02-23: Began updating unit/integration/invariant tests for initializer-based treasury setup.

## Open risks

- Budget treasury immutables are now storage fields (gas/read-cost delta); behavior should remain identical.
- Pre-created-but-uninitialized treasury clone is safe in current single-transaction activation path; future async refactors must preserve initialization ordering/authority guarantees.

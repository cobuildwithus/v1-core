# Kill Budget Temporary Manager Pattern

Status: in_progress
Created: 2026-02-22
Updated: 2026-02-22

## Goal

Remove the per-budget temporary manager/forwarder deployment path so budget stack activation uses `BudgetTCR` as the bootstrap flow manager and transfers manager authority directly to the deployed `BudgetTreasury`.

## Scope

- In scope:
  - Refactor budget stack deployment flow in `BudgetTCR` + deployer/library contracts.
  - Remove `BudgetStackTemporaryManager` usage from deployment helpers.
  - Refactor `BudgetStakeStrategy` to resolve budget treasury via canonical ledger mapping (`budgetForRecipient(recipientId)`).
  - Update unit/integration tests and architecture docs for the new deployment and scoring model.
- Out of scope:
  - Changes under `lib/**`.
  - Introducing CREATE2-based deterministic deployment flows.
  - Changes to `GoalStakeVault` forwarder resolution path outside what is required by this refactor.

## Constraints

- Keep budget activation/removal invariants intact.
- Child flow manager must be handed to the deployed budget treasury during activation.
- Strategy must fail closed for unknown recipient mapping and resolved treasury states.
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- `BudgetTCR._deployBudgetStack` sets child flow manager to `address(this)` during recipient creation and then transfers manager to deployed budget treasury.
- No `BudgetStackTemporaryManager` contract remains in production deployment path.
- `BudgetStakeStrategy` no longer depends on `TreasuryResolver`/forwarder address for budget lookups.
- Tests reflect no-forwarder behavior and continue to pass.
- Architecture docs no longer describe temporary-manager forwarding as the budget stack mechanism.

## Progress log

- 2026-02-22: Drafted plan and mapped all references to temporary manager/forwarder and strategy resolution paths.

## Open risks

- Existing tests that intentionally cover generic treasury forwarding (`TreasuryResolver`) may remain valid for `GoalStakeVault`; only budget stack-specific forwarding assumptions should be removed.

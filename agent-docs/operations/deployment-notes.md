# Deployment Notes

Last updated: 2026-02-26

## Initializer Takeover Guardrail

For any `Initializable` runtime instance (clone/proxy), deployment and initialization must be atomic (same transaction).

- Never expose an uninitialized runtime instance address between transactions.
- Never send funds to, or assign integration roles for, an uninitialized runtime instance.

### Why this matters

If `initialize(...)` is publicly callable and a runtime instance is left uninitialized, any external caller can initialize first and take control of authority/controller/config.

### Current repo status

- `BudgetTreasury` is clone-first in budget stack activation, but canonical wiring initializes it in the same `activateRegisteredBudget(...)` transaction.
- `GoalTreasury` and `GoalRevnetSplitHook` support clone/proxy initialization paths; those are safe only when initialization is atomic.

### Deployment requirements

1. Proxy deployments must pass initializer calldata in proxy construction.
2. Clone deployments must call `initialize(...)` immediately in the factory before returning control.
3. Any future async or multi-transaction init refactor must include an explicit initializer-caller gate or equivalent hardening.

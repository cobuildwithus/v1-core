# Shared Budget Router Strategy (Per Goal)

Status: completed
Created: 2026-02-26
Updated: 2026-02-26

## Goal

Stop deploying one allocation strategy per accepted budget by introducing a single shared per-goal budget router strategy that all budget child flows can use.

## Scope

- In scope:
  - Add a new shared router strategy contract for budget child flows.
  - Add one-time child-flow -> recipientId registration path with strict authorization.
  - Refactor Budget TCR stack deployment to reuse the shared strategy address.
  - Register child flows during budget stack activation.
  - Update deployment/unit tests and architecture docs.
- Out of scope:
  - `lib/**` changes.
  - Changes to goal-flow default strategy behavior.
  - Backward-compatibility shims for pre-existing deployments.

## Constraints

- Preserve fail-closed semantics when budget recipient mapping is missing, treasury code is absent, or treasury resolved probe fails.
- Preserve child sync assumptions (`allocationKey(account, "")` and `accountForAllocationKey` address-key resolver behavior).
- Keep stack deploy path restricted to `BudgetTCR` authority through existing deployer gates.
- Required verification gate for Solidity changes: `pnpm -s verify:required`.

## Acceptance Criteria

- Budget stack activation no longer deploys a new budget strategy per item.
- All budget child flows for one goal share one strategy address.
- Shared strategy context resolves by caller flow (`msg.sender`) using pre-registered recipient mapping.
- Registration is one-time per child flow and restricted to authorized deploy path.
- Existing budget stack deployment and lifecycle tests pass with updated assertions.

## Planned Changes

1. Add `BudgetFlowRouterStrategy` + interface with:
   - one-time `registerFlowRecipient(flow, recipientId)` entrypoint,
   - contextual `currentWeight/canAllocate` using `msg.sender` flow mapping,
   - helper contextual views with explicit `flow` parameter for frontends/tests.
2. Update `BudgetTCRDeployer` to lazily deploy and cache one shared strategy per goal/deployer.
3. Refactor stack deployment lib/component deployer to accept a provided strategy address instead of deploying per-budget strategy.
4. Update `BudgetTCR._deployBudgetStack` to register the new child flow against item recipientId before finalizing stack deployment.
5. Update tests and docs for shared-strategy behavior.

## Risks

- Incorrect child-flow registration could mis-scope weight reads across budgets.
- Contextual strategy reads can confuse non-flow callers unless explicit helper views are used.
- Interface changes for stack deployer mocks may require test fixture updates.

## Validation

- Targeted tests for deployment + strategy routing behavior.
- Full required gate: `pnpm -s verify:required`.

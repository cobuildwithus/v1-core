# 2026-03-12 Exit Router Test Fixtures

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Replace the bespoke fake contracts in `test/juicebox/CobuildExitRouter.t.sol` with higher-fidelity fixtures that exercise the router against real protocol implementations where the repo already has them.

## Scope

- In scope:
  - `test/juicebox/CobuildExitRouter.t.sol`
  - optional shared test helper extraction if it reduces bespoke mocks without touching production code
- Out of scope:
  - production router or terminal behavior changes unless fixture realism exposes a real bug
  - unrelated Juicebox tests

## Constraints

- Prefer real `CobuildCommunityTerminal` and real `GoalDeploymentRegistry`.
- Reuse existing async directory/controller/store patterns from integration coverage instead of bespoke unit-test-only doubles where possible.
- Keep the assertions covering the current router invariants and failure modes.

## Verification

- `forge test test/juicebox/CobuildExitRouter.t.sol --skip test/BudgetTCRDeployments.t.sol --skip test/goals/ManagedBudgetController.t.sol --skip test/goals/BudgetTreasury.t.sol`
- completion workflow: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Outcome

- Replaced bespoke exit-router test doubles with a higher-fidelity harness built around real `CobuildCommunityTerminal`, `GoalDeploymentRegistry`, `CobuildSplitHook`, `CommunityGoalRegistry`, and real community registration.
- Kept only minimal helper-only fixtures for the goal-first-hop cash-out boundary and a directory test hook needed to clear a primary terminal mapping in one negative case.
- Expanded router regression coverage for token-mismatch lineage rejection, non-cash-out goal terminals, missing final native terminal, deadline expiry, and under-min-output enforcement.

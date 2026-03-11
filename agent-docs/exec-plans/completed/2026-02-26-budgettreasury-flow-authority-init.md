# BudgetTreasury Flow Authority Init Hardening

Status: completed
Created: 2026-02-26
Updated: 2026-02-26

## Goal

Fail fast when a `BudgetTreasury` is initialized against a child flow that does not grant the treasury required runtime authority (`flowOperator` and `sweeper`), and require a configured parent flow for residual settlement.

## Scope

- In scope:
  - Add init-time authority invariant checks in `src/goals/BudgetTreasury.sol`.
  - Add/adjust `BudgetTreasury` regression tests and supporting mocks to cover authority mismatch and keep existing behavior intact.
  - Update any test fixture wiring that initializes `BudgetTreasury` with mock flows.
- Out of scope:
  - Changes to goal treasury semantics.
  - Changes under `lib/**`.

## Constraints

- Preserve budget lifecycle semantics and terminal-side-effect retry behavior.
- Keep deployment-time failure explicit and deterministic on miswired flow authority.
- Run required Solidity verification gate: `pnpm -s verify:required`.
- Run completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Acceptance criteria

- `BudgetTreasury.initialize` reverts when `flow.flowOperator()` or `flow.sweeper()` is not `address(this)`.
- `BudgetTreasury.initialize` reverts when `flow.parent()` is `address(0)`.
- Existing budget lifecycle tests continue to pass with updated fixture wiring.
- Required verification passes after completion workflow edits.

## Progress log

- 2026-02-26: Claimed scope in `COORDINATION_LEDGER` and mapped init/runtime authority assumptions in `BudgetTreasury` and related docs.
- 2026-02-26: Added `BudgetTreasury.initialize` fail-fast checks for child-flow `flowOperator`, `sweeper`, and non-zero `parent`.
- 2026-02-26: Added `IBudgetTreasury.FLOW_AUTHORITY_MISMATCH` and updated budget init/deployment fixtures for authority wiring.
- 2026-02-26: Ran completion workflow passes (`simplify`, `test-coverage-audit`, `task-finish-review`); no high/medium findings remained.
- 2026-02-26: Verification evidence:
  - `forge test --match-contract BudgetTreasuryTest` passed (`116`).
  - `forge test --match-contract BudgetTCRStackDeploymentLibTest` passed (`9`).
  - `pnpm -s verify:required` rerun remained red due unrelated in-flight `BudgetTCR` suites (`test/BudgetTCR*.t.sol`) outside this task scope.

## Open risks

- Required full gate currently has unrelated failures in concurrent `BudgetTCR` workstream tests (`test/BudgetTCR*.t.sol`), so cross-suite green status is externally blocked.

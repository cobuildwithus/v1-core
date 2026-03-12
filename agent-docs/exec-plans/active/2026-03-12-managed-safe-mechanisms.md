# 2026-03-12 Managed Safe Mechanisms

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Support Safe-managed mechanism runtimes on managed goals without turning `ManagedBudgetController` into a mechanism-specific adapter.

## Scope

- In scope:
  - `src/teamflow/TeamFlow.sol`
  - targeted TeamFlow and managed-goal tests
  - managed-goal architecture/spec docs that currently imply no mechanism path exists at all for the managed preset
- Out of scope:
  - adding a managed analogue of `AllocationMechanismTCR`
  - adding TeamFlow-specific entrypoints on `ManagedBudgetController`
  - changing managed budget topology or treasury lifecycle semantics
  - introducing a new generic managed mechanism registry in this pass

## Constraints

- Keep `ManagedBudgetController` generic: budget topology, recipient lifecycle, and allocation writes only.
- Mechanism-specific behavior should remain on the mechanism contract itself, managed by the Safe.
- Preserve managed preset invariants: controller stays goal allocator identity and child-flow `recipientAdmin`.
- Keep the implementation minimal and test-backed; favor direct reuse of existing generic recipient APIs.

## Intended change

1. Confirm and document the supported managed path: the Safe deploys a mechanism like `TeamFlow` through its factory, then uses existing controller recipient APIs to attach and weight it on the managed budget flow.
2. Add manager handoff support to `TeamFlow` so Safe authority rotation can be mirrored cleanly for deployed managed mechanisms.
3. Add regression tests covering direct Safe-managed TeamFlow deployment plus attachment on managed budgets, and TeamFlow manager handoff behavior.
4. Update managed-preset docs to describe this supported generic mechanism path without implying a managed mechanism registry exists.

## Verification

- targeted forge tests for TeamFlow and managed-goal integration paths
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s build:sizes`
- completion workflow: `simplify` -> `test-coverage-audit` -> `task-finish-review`

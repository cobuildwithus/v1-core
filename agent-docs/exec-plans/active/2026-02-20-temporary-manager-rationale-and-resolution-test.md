# Temporary Manager Rationale and Resolution Test

Status: completed
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Document why the temporary-manager treasury anchor remains in place and add an integration-level test that proves vault/strategy behavior depends on effective treasury resolution (not deploy/create ordering side effects).

## Scope

- In scope:
  - Add a targeted integration test under `test/BudgetTCRDeployments.t.sol`.
  - Update architecture docs with a concise rationale + CREATE2 revisit trigger.
- Out of scope:
  - CREATE2 migration.
  - Budget stack lifecycle redesign.
  - Changes under `lib/**`.

## Constraints

- Keep runtime behavior unchanged.
- Keep changes narrow and test/documentation focused.
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- New test demonstrates:
  - pre-deploy anchor behavior fails closed,
  - post-deploy forwarding resolves to concrete treasury for both strategy and vault-relevant authorization path.
- Architecture doc clearly states why temporary manager exists and when CREATE2 should be revisited.
- Build and lite tests pass.

## Progress log

- 2026-02-20: Drafted plan.
- 2026-02-20: Added `BudgetTCRDeployments` integration coverage proving pre-deploy fail-closed behavior and post-deploy forwarding resolution for strategy + vault auth path.
- 2026-02-20: Documented temporary-manager rationale and CREATE2 revisit trigger in architecture docs.
- 2026-02-20: Verified with `forge build -q` and `pnpm -s test:lite` (711/711 passing).

## Open risks

- Test setup may require a local ledger mock for deterministic stake values.

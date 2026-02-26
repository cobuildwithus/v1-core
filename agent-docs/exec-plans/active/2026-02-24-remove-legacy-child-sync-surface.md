# Remove Legacy Flow Child-Sync Surface

Status: complete
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Remove dead parent-driven child flow-rate sync queue codepaths now that child sync is pipeline/treasury-driven.

## Scope

- In scope:
  - Remove legacy `Flow` child-sync queue entrypoints and dead internal wrappers.
  - Remove unreachable `FlowRates` child-rate sync internals tied only to that legacy path.
  - Align tests/docs that still reference queue semantics.
- Out of scope:
  - Any `lib/**` changes.
  - Behavioral changes to allocation pipeline or treasury sync logic.

## Constraints

- Preserve current runtime behavior for allocation commit + pipeline child sync and treasury `sync()` flow-rate control.
- Keep public behavior unchanged outside removed dead surfaces.
- Required Solidity verification gate: `pnpm -s verify:required`.
- Run completion workflow passes before handoff (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Acceptance Criteria

1. No remaining runtime `syncChildFlows` queue/rate-sync implementation path in `Flow`/`FlowRates`.
2. Interfaces/tests/docs no longer imply legacy queue-driven child flow-rate sync behavior.
3. Verification and completion workflow passes executed and reported.

## Progress Log

- 2026-02-24: Created plan and claimed coordination scope.
- 2026-02-24: Simplify pass removed no-op tuple placeholders/dead test locals and aligned stale queue-era audit wording; `pnpm -s verify:required` passed.
- 2026-02-24: Test-coverage-audit pass strengthened removed `syncChildFlows` selector coverage to assert failure for privileged (`manager`) and non-privileged callers.
- 2026-02-24: Completion audit reported no high/medium/low findings in scoped changes; additional `pnpm -s verify:required` pass succeeded.

## Open Risks

- Removing legacy surface may break downstream callers/tests that still invoke no-op compatibility methods; these must be updated in-tree.

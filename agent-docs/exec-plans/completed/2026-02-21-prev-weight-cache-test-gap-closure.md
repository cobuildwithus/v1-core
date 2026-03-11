# Previous Weight Cache Test Gap Closure

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Close deterministic test gaps for previous-weight cache behavior so migration bootstrap, wrong-witness-content failure, and cache/commit coherence are explicitly enforced.

## Scope

- In scope:
  - Add/extend flow witness tests for:
    - weight-change updates that ignore witness weight after cache set,
    - invalid previous witness ids/bps content reverting `INVALID_PREV_ALLOCATION`,
    - migration bootstrap from `allocCommit != 0` with unset cache,
    - cache-plus-commit weight coherence assertions.
  - Add test harness accessors needed to inspect/reset cache state in tests.
- Out of scope:
  - Any changes under `lib/**`.
  - Runtime protocol behavior changes in `src/**`.

## Constraints

- Keep behavior checks aligned with current fail-closed witness semantics.
- Preserve existing test patterns and fixtures.
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- Deterministic tests exist for each requested behavior gap.
- Tests assert both commitment hash and `allocWeightPlusOne` coherence where relevant.
- Required verification commands pass.

## Progress Log

- 2026-02-21: Subagent audit completed across four requested ideas; identified missing deterministic coverage for migration bootstrap and explicit cache invariant checks.
- 2026-02-21: Added test-harness cache accessor/reset methods and expanded `FlowAllocationsWitness` tests to cover missing behaviors.
- 2026-02-21: Verification passed (`forge build -q`, `pnpm -s test:lite`).

## Open Risks

- Revert-selector expectations for malformed/unsorted witness payloads remain intentionally separate from `INVALID_PREV_ALLOCATION` (e.g., `NOT_SORTED_OR_DUPLICATE`).

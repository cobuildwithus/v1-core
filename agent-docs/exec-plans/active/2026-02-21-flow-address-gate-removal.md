# Flow Address-Gating Oracle Removal

## Goal
Remove deprecated address-gating oracle logic from the on-chain protocol surface so Flow remains permissionless at protocol level.

## Scope
- Remove deprecated oracle dependencies from Flow contracts/interfaces/libraries/storage.
- Remove deprecated oracle wiring and behavior/tests from Flow test fixtures and suites.
- Remove protocol/docs references that describe deprecated oracle enforcement in core Flow contracts.

## Constraints
- Do not modify `lib/**`.
- Preserve all non-gating Flow recipient/allocation behavior.
- Keep UMA/TCR oracle functionality unchanged (out of scope).

## Acceptance criteria
- No production contract references to deprecated address-gating oracle types/state remain.
- Flow init/config interfaces and constructors no longer require deprecated oracle params.
- Deprecated-oracle test mocks and assertions are removed or rewritten.
- Verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress log
- 2026-02-21: Plan created.

## Open risks
- Flow interface changes are breaking for downstream integrations compiled against removed fields/methods/events.

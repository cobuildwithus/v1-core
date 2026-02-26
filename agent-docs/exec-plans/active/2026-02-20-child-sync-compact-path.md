# Child Sync Compact Path

Status: complete
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Make the gas-lean compact child-sync path canonical by removing duplicated recipient/bps payloads from parent-provided child sync requests while preserving strict witness/commit safety semantics.

## Scope

- In scope:
  - Add compact child-sync request shape to `ICustomFlow`.
  - Promote compact child-sync allocation to the canonical 5-arg `allocate` entrypoint.
  - Promote compact child resync to canonical `syncAllocationCompact`.
  - Remove legacy child-sync API call shapes.
  - Add focused tests for compact success, strict missing/invalid checks, and best-effort child call failures.
- Out of scope:
  - Changes under `lib/**`.

## Constraints

- Preserve existing strict behavior for required child-sync coverage in ledger mode.
- Preserve best-effort semantics for downstream child sync call failures.
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- New compact path compiles and is externally callable.
- Parent compact allocation succeeds on valid compact witness payloads.
- Parent compact allocation reverts on missing or invalid compact witness payloads.
- Parent compact allocation does not revert when downstream child sync call fails.

## Progress log

- 2026-02-20: Drafted plan and scoped additive compact API + test coverage.
- 2026-02-20: Promoted compact mode to canonical API by removing legacy child-sync call shapes and routing parent auto-sync through `syncAllocationCompact`.
- 2026-02-20: Added compact-path coverage in `FlowBudgetStakeAutoSync` and `FlowBudgetStakeStrategyStaleUnits`.
- 2026-02-20: Verified with `forge build -q` and `pnpm -s test:lite` (pass).

## Open risks

- Removing legacy call shapes requires downstream SDK/client ABI updates.
- Compact path reduces calldata size but does not eliminate per-child external call cost; large fan-out remains gas-bounded.

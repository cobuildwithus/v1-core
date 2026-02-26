# Proposal 1 Previous Weight Cache

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Cache the previously committed allocation weight on-chain per `(strategy, allocationKey)` and use that cached value as the canonical previous weight for allocation application, ledger checkpointing, and child-sync delta detection.

## Scope

- In scope:
  - Add `allocWeightPlusOne` storage mapping in `FlowTypes.Storage`.
  - Update allocation apply paths to populate/use cached previous weight and atomically write next cached weight with commit updates.
  - Route `CustomFlow` allocate/sync/clear/preview parent witness handling to cache-first previous-weight resolution.
  - Update affected tests and docs for the new semantics.
- Out of scope:
  - Changes under `lib/**`.
  - External witness encoding/API changes.

## Constraints

- No live deployments exist yet (repo policy), so simplification is preferred over migration scaffolding.
- Keep witness ids/bps validation deterministic and fail-closed.
- Ensure cache and commit updates remain atomic in the same mutation transaction.
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- Existing-commit allocation mutation paths use cached previous weight when present.
- First-commit paths preserve strict empty previous witness semantics.
- Ledger checkpoint + child-sync delta detection receive the same previous weight used by allocation apply logic.
- Cache is initialized when needed and updated on every successful allocation commit write.
- Tests cover cache-first behavior and guardrails around invalid witness ids/bps.

## Progress log

- 2026-02-21: Confirmed current `prevWeight` witness flow and centralized commit write in `FlowAllocations`.
- 2026-02-21: Confirmed storage placement decision for this repo state (`FlowTypes.Storage` append acceptable given no live deployments).
- 2026-02-21: Added `allocWeightPlusOne` to `FlowTypes.Storage` and updated `FlowAllocations` to initialize/update cache atomically with allocation commit writes.
- 2026-02-21: Routed `CustomFlow` allocate/sync/clear/preview previous-state handling through cache-first previous-weight resolution with witness bootstrap fallback.
- 2026-02-21: Updated witness/ledger/child-sync tests for cache-first semantics and added checkpoint assertion coverage for cached `prevWeight`.
- 2026-02-21: Updated architecture/reference docs for on-chain previous-weight source-of-truth semantics.
- 2026-02-21: Verification passed (`forge build -q`, `pnpm -s test:lite`).

## Open risks

- Changing previous-weight semantics can flip revert expectations in witness tests that currently treat wrong witness weight as invalid.
- Child-sync stale-witness cases must still fail for stale ids/bps/commit content, not just weight mismatch.

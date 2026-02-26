# Flow ERC-7201 Storage Domains

Status: active
Created: 2026-02-23
Updated: 2026-02-23

## Goal

- Replace monolithic `Flow` storage access with ERC-7201 namespaced storage domains (`cfg`, `recipients`, `alloc`, `rates`, `pipeline`, child-flow sets) so domain growth does not shift other domain roots, while preserving runtime behavior.

## Success criteria

- `src/storage/FlowStorage.sol` exposes ERC-7201 accessor libraries for each Flow storage domain.
- `Flow`/`CustomFlow` and Flow libraries no longer depend on `Storage internal fs` aggregate access.
- Flow behavior/test surface remains green under required verification.

## Scope

- In scope:
- `src/storage/FlowStorage.sol` migration to namespaced storage accessors.
- Flow callsite rewiring in `src/Flow.sol`, `src/flows/CustomFlow.sol`, and `src/library/Flow*.sol`.
- Harness/test updates required for compile or regression coverage.
- Out of scope:
- Behavior/policy changes to allocation, rate sync, treasury wiring, or hook semantics.
- Changes under `lib/**`.
- Broad documentation refresh beyond this execution plan unless architecture boundaries materially change.

## Constraints

- Technical constraints:
- Keep namespace ids/slot constants stable and unique.
- Preserve revert surfaces and event semantics (no intentional external behavior changes).
- Keep edits mechanical and domain-typed to reduce accidental coupling.
- Product/process constraints:
- Required verification before handoff: `pnpm -s verify:required`.
- Run simplification pass and completion audit before final handoff.

## Risks and mitigations

1. Risk: Incorrect ERC-7201 root constants could alias/corrupt domains.
   Mitigation: Keep namespace ids explicit in code comments/annotations and use fixed precomputed roots.
2. Risk: Missed callsite migration causes compile/runtime breakage in critical flow paths.
   Mitigation: Use repository-wide search for each legacy field name and verify no flat access remains.
3. Risk: Subtle behavior changes from refactor noise in high-risk flow libraries.
   Mitigation: Keep the change mechanical (path-only field access updates) and run required build/tests.

## Tasks

1. Add namespaced storage accessors in `FlowStorage`.
2. Migrate `Flow`/`CustomFlow` and libraries to explicit domain storage refs.
3. Update harnesses/tests for namespaced access and manager-synced queue behavior.
4. Run required verification gates and audits.

## Decisions

- Adopt ERC-7201 namespaced roots per Flow domain (`cfg`, `recipients`, `alloc`, `rates`, `pipeline`, child-flow sets).
- Keep legacy `FlowTypes.Storage` type only for compatibility in harness/tests; runtime no longer uses aggregate `fs` storage.

## Verification

- Commands to run:
- `forge build -q`
- `pnpm -s verify:required`
- Expected outcomes:
- Build succeeds with no errors.
- Required gate passes (shared build + lite shared tests).

## Progress log

- 2026-02-23: Migrated `FlowStorageV1` from aggregate `Storage internal fs` to ERC-7201 namespaced domain accessors, including namespaced child-flow sets.
- 2026-02-23: Rewired `Flow`, `CustomFlow`, and Flow libraries to domain-specific storage refs; removed runtime dependency on `fs`.
- 2026-02-23: Updated `test/harness/TestableCustomFlow.sol` for namespaced accessors.
- 2026-02-23: Coverage audit added manager-synced child regression tests in `test/flows/FlowChildSyncBehavior.t.sol` and `test/flows/FlowAllocationsChildSyncCases.t.sol`.
- 2026-02-23: Verification evidence: `forge build -q` pass; `pnpm -s verify:required` pass (post-refactor, post-audit).

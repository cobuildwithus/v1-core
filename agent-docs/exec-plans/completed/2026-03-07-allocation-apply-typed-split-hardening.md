# 2026-03-07 Allocation Apply Typed Split and Hardening

## Goal

Replace the flat, easy-to-misuse allocation apply helper surface with typed edit and maintenance request paths, while hardening the core apply boundary so future internal callers cannot silently persist malformed allocation state or pass inconsistent previous-weight context.

## Scope

- `src/library/FlowAllocations.sol`
- `src/library/CustomFlowAllocationEngine.sol`
- `src/flows/CustomFlow.sol`
- `src/library/CustomFlowPreview.sol` if preview helpers need shared typed state
- `test/harness/TestableCustomFlow.sol`
- Allocation-focused tests and coverage harnesses under `test/flows/**`

## Constraints

- Preserve external `CustomFlow` behavior and interface shape.
- Keep maintenance sync semantics that tolerate removed recipients while still using stored canonical allocation composition.
- Fail closed on malformed allocation structure at the core edit/apply boundary.
- Do not introduce compatibility shims or legacy wrapper layering if a simpler typed split is available.

## Planned Changes

1. Introduce typed structs for allocation vectors and apply context/request data instead of long flat parameter lists.
2. Split allocation application into explicit allocation-edit and maintenance-sync entrypoints so call intent is visible in code review.
3. Harden the core apply path to reject inconsistent prior weight and malformed allocation vectors before snapshot/state writes.
4. Update `CustomFlow` and test harness callers to use the typed engine surface.
5. Add regression coverage for wrong previous-weight, malformed allocation vectors, and stable maintenance behavior.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Targeted Forge allocation tests during iteration as needed

## Risks

- Refactoring the core apply path can accidentally change snapshot write timing or pool-unit delta behavior.
- Tightening validation in the shared helper can invalidate existing harness tests that currently exercise unchecked misuse paths.
- `src/flows/CustomFlow.sol` and test harnesses are shared hot spots; avoid clobbering unrelated worktree edits.

## Progress

- 2026-03-07: Added typed `FlowAllocations` request structs and split explicit allocation-edit vs maintenance-sync apply helpers.
- 2026-03-07: Updated `CustomFlowAllocationEngine`, `CustomFlow`, and the test harness to use the typed helper surface.
- 2026-03-07: Hardened the core apply path to reject mismatched cached-vs-supplied previous weight and malformed allocation vectors.
- 2026-03-07: Added direct misuse-regression coverage for wrong previous weight, zero-ppm allocations, and scaled-sum mismatch.
- 2026-03-07: Verified targeted allocation suites and `pnpm -s verify:required`; simplify pass found no additional behavior-preserving cleanup worth landing.

## Progress

- 2026-03-07: Replaced the flat apply wrapper surface with typed `FlowAllocations` request structs and explicit edit vs maintenance entrypoints.
- 2026-03-07: Hardened the core apply boundary to reject previous-weight/cache mismatches and malformed allocation vectors before snapshot writes.
- 2026-03-07: Updated `CustomFlow`, the allocation engine, and harness call sites to use typed requests instead of long flat argument lists.
- 2026-03-07: Added regression coverage for wrong previous weight, zero/sum-invalid allocation vectors, invalid recipient ids, removed recipients, and malformed maintenance payloads.
Status: completed
Updated: 2026-03-07
Completed: 2026-03-07

# Proposal 3 PPM Terminology and Allocation Scale Alias

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Reduce allocation-scale confusion by standardizing flow allocation terminology to parts-per-million (scaled) while preserving existing external behavior and numeric scale.

## Scope

- In scope:
  - Keep the numeric allocation scale at `1_000_000`.
  - Add explicit allocation-scale alias constant (`ALLOCATION_SCALE`) in shared flow initialization constants.
  - Update flow-facing NatSpec/comments from `BPS` wording to scaled/parts-per-million wording on targeted interfaces/libraries.
  - Rename internal variable/event parameter identifiers where safe (non-ABI-affecting) in flow allocation paths.
  - Add a focused test asserting scale invariants (`PERCENTAGE_SCALE == 1_000_000`, alias parity).
- Out of scope:
  - Breaking external API renames.
  - Changes under `lib/**`.
  - Broad non-flow-module terminology migrations.

## Constraints

- Preserve external/public function names and existing runtime behavior.
- Keep revert selectors and core semantics unchanged unless explicitly required.
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- Targeted flow docs/NatSpec no longer describe allocation splits as BPS where the scale is `1_000_000`.
- Shared alias constant `ALLOCATION_SCALE` exists and is used as canonical wording for allocation scaling.
- Existing `PERCENTAGE_SCALE` behavior remains intact and equal to `ALLOCATION_SCALE`.
- Test coverage includes direct assertion of scale value and alias equivalence.

## Progress Log

- 2026-02-21: Drafted plan and identified target files (`IFlow`, `FlowAllocations`, `FlowInitialization`, `FlowStorage`, flow init tests).
- 2026-02-21: Added `FlowInitialization.ALLOCATION_SCALE = 1e6` alias and wired `PERCENTAGE_SCALE` initialization through the alias.
- 2026-02-21: Updated targeted flow NatSpec/comments from BPS wording to scaled/parts-per-million wording and renamed internal allocation variables from `bps` to `allocationScaled` across witness/commit/allocation paths.
- 2026-02-21: Added scale invariants in `FlowInitializationAndAccessInit` asserting `PERCENTAGE_SCALE == 1_000_000` and alias parity with `FlowInitialization.ALLOCATION_SCALE`.
- 2026-02-21: Verification passed with `forge build -q` and `pnpm -s test:lite` (803 tests passed, 0 failed).

## Open Risks

- Broad BPS wording appears in non-flow modules; this change intentionally scopes to flow allocation surfaces to avoid unintended semantic churn.

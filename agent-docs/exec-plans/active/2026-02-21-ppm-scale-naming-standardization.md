# PPM Scale Naming Standardization

Status: in_progress
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Standardize all 1e6 percentage-like scale naming to `PPM` terminology (`SCALE_1E6`, `*Scaled`) and reserve `BPS` naming for true 1e4 basis-point math only.

## Scope

- In scope:
  - Rename 1e6 scale constants/fields/errors/params in `src/**` from `PERCENTAGE/BPS` naming to `PPM` naming.
  - Update dependent interfaces/call sites/tests/harnesses for renamed public API symbols.
  - Preserve true 1e4 `BPS` naming and behavior (for example arbitrator slashing math).
- Out of scope:
  - Any `lib/**` changes.
  - Behavioral/economic changes.

## Constraints

- No semantic changes: naming-only refactor for 1e6-scaled values.
- Keep 1e4 basis-point paths using `BPS` naming.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- No remaining 1e6 scale constants named `*BPS*` or `PERCENTAGE_SCALE` in production code.
- Public/internal names for 1e6 percentages use `PPM` terminology consistently.
- Build/tests pass with updated names.

## Progress Log

- 2026-02-21: Scoped affected source and test surfaces; identified true 1e4 `BPS` paths to preserve.
- 2026-02-21: Renamed 1e6 scale symbols in core source (`PERCENTAGE_SCALE`/`*BPS*` -> `SCALE_1E6`/`*Scaled`) across Flow, goal treasury/hook, and budget stake ledger modules.
- 2026-02-21: Updated dependent interfaces and key test/harness call sites and constants to match renamed PPM symbols.
- 2026-02-21: Verification blocked by existing non-PPM compile failures in UMA-success-assertion/treasury inheritance surfaces (`BudgetTreasury`, `GoalTreasury`) and pre-existing BudgetTCR interface arity drift.

## Open Risks

- Interface symbol renames require broad test/harness call-site updates; compile failures will catch misses.

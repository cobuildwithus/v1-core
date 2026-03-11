# Proposal 5 Calldata-Memory Dedup

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Reduce duplicated calldata/memory logic in flow allocation ledger-mode internals while preserving behavior and keeping gas-impact bounded.

## Scope

- In scope:
  - Refactor duplicated calldata/memory internal helpers in `GoalFlowLedgerMode` into shared core helpers with thin wrappers.
  - Keep external behavior and interfaces unchanged.
  - Add differential tests that compare calldata-path vs memory-path outputs for randomized vectors.
- Out of scope:
  - Changes under `lib/**`.
  - External API changes.

## Constraints

- Preserve strict fail-closed behavior and existing revert semantics on invalid states.
- Prefer Option B style (centralize shared arithmetic/merge logic first; avoid broad allocation-path rewrites).
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- Duplicated merge/arithmetic logic between calldata/memory helper paths is materially reduced.
- Differential test demonstrates parity between calldata and memory detect paths across randomized vectors.
- Build and lite test suite pass.

## Progress Log

- 2026-02-21: Scoped duplication to `GoalFlowLedgerMode` (`checkpointAndDetectBudgetDeltas*`, `detectBudgetDeltas*`, and budget-delta merge helpers).
- 2026-02-21: Unified detect-path merge logic on shared memory core helpers with thin calldata wrappers/copies.
- 2026-02-21: Added parity harness + differential fuzz test (`GoalFlowLedgerModeParity`) to assert calldata vs memory equivalence.
- 2026-02-21: Verification complete (`forge build -q`, `pnpm -s test:lite`).

## Open Risks

- Any calldata->memory bridging added for clarity can increase gas in allocation-ledger paths; verify no behavior regressions and monitor gas profile deltas.

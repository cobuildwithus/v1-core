# Budget Ledger Merge + StakeVault Slash Dedup

Status: complete
Created: 2026-03-02
Updated: 2026-03-02

## Goal

Apply two behavior-preserving simplifications:

- remove calldata->memory merge overhead in `BudgetStakeLedger.checkpointAllocation` by using the shared sorted-merge primitive directly on calldata.
- deduplicate `StakeVault` juror/underwriter slashing paths behind one internal helper while preserving auth checks, state writes, transfer order, and event semantics.

## Scope

- In scope:
  - `src/goals/BudgetStakeLedger.sol`
  - `src/goals/StakeVault.sol`
  - impacted tests under `test/goals/**` only if needed
  - completion-workflow outputs for this change
- Out of scope:
  - `lib/**`
  - external ABI changes
  - behavior changes to slashing math, checkpoint ordering, or lifecycle transitions

## Constraints

- Preserve fail-closed accounting semantics (`ALLOCATION_DRIFT`, underflow guards, auth/error paths).
- Preserve sorted recipient merge assumptions and deterministic merge output.
- Preserve slashing math formulas and transfer/write ordering.
- Required verification gate: `pnpm -s verify:required`.

## Acceptance Criteria

- `BudgetStakeLedger` no longer constructs a memory merge context from calldata arrays for checkpoint merge processing.
- Duplicate slashing logic in `StakeVault` is centralized without changing externally observable behavior.
- Required verification gate passes.
- Completion workflow passes are executed (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Progress Log

- 2026-03-02: Claimed ledger scope and implemented calldata merge refactor in `BudgetStakeLedger` using `SortedRecipientMerge`.
- 2026-03-02: Implemented shared `_slashStake` helper in `StakeVault` and routed juror/underwriter wrappers through it.
- 2026-03-02: Completion workflow passes run (`simplify` -> `test-coverage-audit` -> `task-finish-review`); added regression tests for merge determinism/drift and slash no-op event guarantees.
- 2026-03-02: Required gate executed (`pnpm -s verify:required`) and failed due pre-existing unrelated test syntax errors in `test/*` (typed function-cast parse errors around `ERC20VotesArbitrator.initialize`), not in scoped files.

## Open Risks

- Subtle state-order regressions in slashing path if helper sequencing diverges from prior duplicated implementations.
- Merge precondition remains caller-sorted arrays; malformed upstream ordering still depends on existing assumptions.

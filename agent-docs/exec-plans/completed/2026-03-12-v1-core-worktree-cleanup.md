# 2026-03-12 v1-core Worktree Cleanup

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

Clean up the stale `v1-core` dirty worktree after parallel streams ended, preserve only coherent/validated work, move stale plan docs out of `active`, and finish with a clean repo state.

## Scope

- `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`
- stale plan docs under `agent-docs/exec-plans/active/`
- completed-plan docs under `agent-docs/exec-plans/completed/`
- dirty managed-preset / budget-stack / community-registry files surfaced by `git status`
- related docs/tests as needed
- exclude `lib/**`

## Constraints

- Treat prior agent rows as stale; user confirmed no other workers are active.
- Do not "clean" the tree into a broken `HEAD`; keep any dirty changes that current tracked code already depends on.
- Prefer reverting generated/noise artifacts rather than committing them.
- Any retained Solidity changes must pass required verification and completion workflow before handoff.

## Cleanup Rules

1. Classify each dirty change as one of:
   - required to make current tracked code consistent,
   - coherent completed work worth validating and committing,
   - stale/generated noise to revert or delete.
2. Remove stale active-plan duplicates when the matching completed plan already exists.
3. Move or keep completed plans only when the associated code/docs are retained.
4. End with an empty active coordination ledger unless new work remains.

## Expected End State

- no stale agent rows in `COORDINATION_LEDGER.md`
- no duplicate completed plans lingering in `active/`
- generated deploy/doc noise reverted unless explicitly needed
- retained code/docs committed only after verification
- clean `git status`

## Progress Log

- Classified current dirty files into retained protocol work vs generated/noise artifacts and restored the generated deploy/doc churn.
- Moved plan docs already marked completed out of `active/` and into `completed/`.
- Promoted the blocked managed-removal fail-close plan to completed after the stale unrelated property-test failure was fixed and the required gates passed.
- Tightened the stale child-sync fuzz bound in `test/flows/FlowLedgerChildSyncProperties.t.sol` so the property always exercises a real effective-weight change.
- Ran the required Solidity gates successfully:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
- Ran completion workflow passes:
  - simplify: no further cleanup needed,
  - test-coverage-audit: added managed-controller assertions that controller-owned terminal sync detaches the ledger recipient mapping immediately,
  - task-finish-review: no findings in the retained scope.

# Child Sync Debt Lock + Allocation Mechanism Recipient Cap

Status: completed
Created: 2026-03-03
Updated: 2026-03-03

## Goal

Close stale child-sync influence risk by adding simple account-level child-sync debt gating with permissionless one-by-one repair, and hard-cap AllocationMechanismTCR active recipients at 7 per budget.

## Scope

- In scope:
  - Add child-sync debt state/gating/repair APIs to `GoalFlowAllocationLedgerPipeline`.
  - Add tests covering debt open/block/repair lifecycle.
  - Add hardcoded active mechanism recipient cap (`7`) in `AllocationMechanismTCR`.
  - Add tests covering cap enforcement and active-count accounting behavior.
  - Update architecture/reference docs for the new debt-gating semantics.
- Out of scope:
  - Removing parent child-sync gas stipend.
  - Generalized configurable caps or governance-tunable parameters.
  - Modifying `lib/**`.

## Constraints

- Preserve best-effort parent allocation commit behavior for initial child-sync failures.
- Prevent follow-up parent allocation updates for accounts with unresolved child-sync debt.
- Keep repair permissionless and budget-scoped (one debt entry per budget).
- Keep implementation simple and localized (pipeline + AllocationMechanismTCR + tests/docs).
- Run required Solidity gate before handoff: `pnpm -s verify:required`.

## Acceptance Criteria

- Parent allocation commit can still succeed when child sync fails/skips due gas/revert, but debt is recorded.
- Subsequent parent allocation commits for that account revert until debt is repaired/cleared.
- Permissionless repair call can clear debt on success, or clear stale debt when target is unavailable/no-commit.
- `AllocationMechanismTCR` activation reverts once 7 active mechanism recipients are already active.
- Active recipient count decrements when mechanisms are stopped/removed.

## Progress log

- 2026-03-03: Plan opened.
- 2026-03-03: Implemented child-sync debt lock/repair in pipeline, hard-capped `AllocationMechanismTCR` active recipients at 7, added coverage, and updated architecture/spec docs.
- 2026-03-03: Ran required verification and completion workflow (`simplify` -> `test-coverage-audit` -> `task-finish-review`), then addressed audit follow-ups.

## Open risks

- Debt gating intentionally trades UX for mechanism safety; allocators can be temporarily blocked until repair.
- Any edge case that leaves debt uncleared must have explicit stale-clear path to avoid sticky lock.

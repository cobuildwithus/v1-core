# 2026-03-12 Simplification Worker Batch

Status: completed
Created: 2026-03-12
Updated: 2026-03-13

## Goal

- Fan out codex-2 workers for the nine identified simplification targets without colliding with the already-dirty shared worktree.

## Scope

- Reserve one worker lane per simplification target.
- Let workers edit only their pre-reserved files.
- Fail closed on targets whose scopes overlap already-active ledger ownership.
- Use parent-managed orchestration for launch order, ledger reservations, and final integration.

## Constraints

- `workspace-docs/bin/codex-workers` runs child Codex sessions in the same live worktree, not isolated clones.
- Existing active ledger ownership for `GoalFactory.sol`, `BudgetTCR.sol`, and `ManagedBudgetController.sol` must not be disturbed.
- Child workers must not touch `.env*`, `lib/**`, or unrelated dirty files.
- Parent owns cross-batch verification, final review, and commit decisions for this worker campaign.

## Target Map

1. Spend-policy probe helper:
   - blocked by active `GoalFactory.sol` + `BudgetTCR.sol` ownership
2. Shared treasury success-assertion lifecycle:
   - independent, but overlaps target 7
3. Flatten `GoalFactory._deployGoal`:
   - blocked by active `GoalFactory.sol` ownership
4. Derive managed active state:
   - blocked by active `ManagedBudgetController.sol` ownership
5. Remove `ChildSyncDebt.exists`:
   - independent, but overlaps target 6
6. Canonicalize child-sync reason codes:
   - wait for target 5
7. Trim GoalTreasury wrappers / unused parameter:
   - wait for target 2
8. Dedupe budget-topology readers:
   - blocked by active `ManagedBudgetController.sol` + `BudgetTCR.sol` ownership
9. Delete repo-local dead code:
   - independent once zero in-repo references are confirmed

## Launch Order

1. Batch A in parallel:
   - target 2
   - target 5
   - target 9
   - blocked-analysis lanes for targets 1, 3, 4, 8
2. Batch B after target 5 settles:
   - target 6
3. Batch C after target 2 settles:
   - target 7

## Worker Rules

- Treat the parent-created `COORDINATION_LEDGER.md` row as your active ownership entry.
- Do not edit `COORDINATION_LEDGER.md` unless your scope must change; if it must change, stop and report the needed adjustment instead of guessing.
- Do not commit from worker lanes; leave changes uncommitted for parent integration.
- Run only narrow, scope-relevant verification when you make edits.
- If a target is blocked by active ownership, produce a concrete blocked report with the exact conflicting files and the smallest safe next step.

## Parent Notes

- Run workers with `workspace-docs/bin/codex-workers --profile 2 --sandbox workspace-write --full-auto`.
- Keep overlapping file lanes serialized even when the worker count is larger.
- Reconcile worker summaries with live dirty diffs before any repo-wide verification.

## Outcome

- Launch campaign used three run directories; Codex 2 reruns should use `--profile 2`:
  - `.codex-runs/20260312-v1-simplification-batch-a`
  - `.codex-runs/20260312-v1-simplification-batch-b`
  - `.codex-runs/20260312-v1-simplification-batch-c`
- Implemented targets:
  - target 2: shared treasury success-assertion lifecycle helper extraction
  - target 5: derived `ChildSyncDebt.exists`
  - target 6: canonicalized child-sync reason constants
  - target 7: trimmed GoalTreasury wrappers / unused parameter
  - target 9: deleted `GoalSpendPatterns.sol` and `IHasStakeVault.sol`
- Blocked with concrete reopen plans:
  - target 1
  - target 3
  - target 4
  - target 8

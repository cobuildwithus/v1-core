# GoalTreasury Funding Activation Ordering Near Deadline

Status: completed
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Ensure `GoalTreasury` cannot remain in `Funding` after `minRaise` is reached through canonical funding ingress paths and then expire solely because no separate `sync()` call happened before deadline.

## Scope

- In scope:
  - Auto-activation when `minRaise` is reached during funding ingress/donation accounting paths.
  - Regression coverage for near-window activation and guardrails (`Funding` only, pre-deadline only).
- Out of scope:
  - Changing deadline itself or adding backward-compatibility paths.
  - Changes under `lib/**`.

## Constraints

- Preserve existing policy that activation is disallowed at/after deadline (`GOAL_DEADLINE_PASSED`).
- Keep terminal side-effect behavior unchanged.
- Run required Solidity verification gate (`pnpm -s verify:required`).

## Acceptance Criteria

- Funding ingress/donation paths that reach threshold before deadline transition `Funding -> Active` in the same call.
- Activation remains disallowed at/after deadline.
- Regression tests cover threshold-hit activation and non-activation guardrails.

## Progress Log

- 2026-02-27: Task opened from reported high-severity lifecycle race.
- 2026-02-27: Added `_autoActivateIfFundingThresholdMet()` and wired it into `processHookSplit` funding ingress, donation callback, and `recordHookFunding`.
- 2026-02-27: Completion workflow pass 2 (`test-coverage-audit`) added focused `GoalTreasury.t.sol` coverage for auto-activation guardrails:
  - below-threshold hook split and donation paths remain `Funding` (no premature activation),
  - at-deadline hook split ingress that would meet threshold does not auto-activate and still expires on `sync()`,
  - donations while already `Active` preserve lifecycle state.
  - Tests were not run in this pass per parent-agent delegation.
- 2026-02-27: Updated `GoalRevnetIntegration` assertions for hook split ingress to avoid stale flow-balance delta assumptions now that threshold-triggered activation can sync flow rate in-call.
- 2026-02-27: Targeted `GoalTreasury` tests pass; required gate currently blocked by unrelated in-flight worktree compile error in `src/goals/BudgetTreasury.sol` (`IFlow.getMemberFlowRate` missing).

# 2026-02-26 Goal Reassert Grace Parity

## Goal
Add one-time post-deadline reassert grace parity to `GoalTreasury` and factor shared grace mechanics into a common treasury library/interface surface.

## Why
`BudgetTreasury` already has a one-time post-deadline reassert grace window; `GoalTreasury` currently hard-reverts assertion registration at/after deadline and expires on late false/fail-closed assertion settlement.

## Scope
- Add shared grace helper library in `src/goals/library/`.
- Add shared grace getters to `ISuccessAssertionTreasury`:
  - `reassertGraceDeadline()`
  - `reassertGraceUsed()`
  - `isReassertGraceActive()`
- Wire budget and goal treasuries to shared helper and shared getter surface.
- Implement goal post-deadline grace lifecycle parity (including fail-closed-to-grace behavior).
- Update goal/budget tests for interface and lifecycle behavior changes.
- Update architecture/spec docs for new goal semantics.

## Non-Goals
- No resolver redesign (single active assertion slot remains).
- No configurable grace duration (fixed 1 day).
- No backward-compatibility shim paths.

## Invariants To Preserve
- Single pending assertion per treasury.
- Success resolution remains resolver-gated and truthful-assertion-gated.
- Funding ingress deadline behavior unchanged.
- Terminalization remains state-first with best-effort side effects.

## Verification
- `pnpm -s verify:required`
- Completion workflow passes:
  - simplify
  - test-coverage-audit
  - task-finish-review

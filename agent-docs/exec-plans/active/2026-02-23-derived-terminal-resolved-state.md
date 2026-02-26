# Derive Resolved From Terminal State

Status: completed
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Remove redundant `_resolved` storage from both treasuries and derive `resolved()` strictly from terminal lifecycle state.

## Scope

- In scope:
  - Remove `_resolved` state variable from `GoalTreasury` and `BudgetTreasury`.
  - Replace dual guards (`_resolved || _isTerminalState(...)`) with terminal-state checks.
  - Make `resolved()` and lifecycle status fields derive from `_isTerminalState(_state)`.
- Out of scope:
  - Lifecycle policy/economic behavior changes.
  - Any changes under `lib/**`.

## Constraints

- Preserve externally visible behavior.
- Keep terminal-state transitions authoritative.
- Required verification for Solidity edits: `pnpm -s verify:required`.

## Acceptance criteria

- No treasury stores `_resolved`.
- `resolved()` returns `true` iff `_state` is terminal.
- Existing call paths and tests pass with unchanged behavior.

## Progress log

- 2026-02-23: Identified all `_resolved` reads/writes in both treasuries.
- 2026-02-23: Removed `_resolved` from `GoalTreasury` and `BudgetTreasury`; switched guards and lifecycle status fields to derived terminal-state checks.
- 2026-02-23: Added/updated targeted lifecycle-status regression coverage in goal/budget treasury suites (committed separately as `486efe2`).
- 2026-02-23: Verification run complete (`pnpm -s test:goals:shared`, `pnpm -s verify:required`).
- 2026-02-23: Completion audit run; reported lifecycle/API behavior drift in the same files tied to other in-flight edits. Deferred per user instruction to avoid modifying other agents' changes.

## Open risks

- Deferred (out-of-scope for this task): concurrent in-flight edits in treasury files introduce lifecycle/API behavior drift (for example terminal `sync()` no-op semantics and failure-path surface changes). Follow-up owner: active treasury lifecycle stream; this refactor intentionally did not alter those paths per user direction.

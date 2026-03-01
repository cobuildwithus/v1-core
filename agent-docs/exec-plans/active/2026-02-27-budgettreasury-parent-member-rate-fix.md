# BudgetTreasury Parent Member-Rate Trust Fix

Status: in_progress
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Remove third-party inbound stream influence from `BudgetTreasury.sync()` outflow targeting by sourcing active incoming rate from the trusted parent flow member rate only.

## Scope

- In scope:
  - `BudgetTreasury` incoming-rate derivation and parent-surface initialization checks.
  - Regression tests for spoofed non-parent inflow manipulation.
  - Mock updates required for parent member-rate reads in budget-related tests/invariants.
  - Architecture/spec doc updates that describe budget target-rate semantics.
- Out of scope:
  - Changing permissionless `sync()` model.
  - Introducing backward-compatibility paths.
  - Any `lib/**` changes.

## Constraints

- Preserve budget lifecycle/state-machine behavior and terminal side-effect behavior.
- Keep trusted-core strictness (typed interface calls, fail-fast on invalid required dependencies).
- Run required Solidity verification gate (`pnpm -s verify:required`) before handoff.
- Run completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`) for this non-trivial code change.

## Acceptance Criteria

- Active `BudgetTreasury.targetFlowRate()` reflects parent member flow rate to the child budget flow (non-negative clamp), not `net + outgoing`.
- Permissionless calls that only manipulate unrelated/unsolicited child flow net state cannot ratchet outflow above trusted parent member rate.
- Initialization fails for invalid parent surface wiring used by sync logic.
- Existing budget stack tests/invariants remain compatible with the trusted-parent-rate model.
- Docs no longer claim budget active target is `net + outgoing`.

## Progress Log

- 2026-02-27: Task opened from confirmed critical sync-spoof finding and approved fix direction (trusted parent member rate).

# 2026-03-12 Managed Budget Prune Fallback

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Confirm whether managed budget terminalization still leaves controller state stale when `syncBudgetTreasuries(...)` triggers a terminal budget under the controller's own `nonReentrant` context.
- If so, make controller-initiated terminalization clean up locally instead of depending on the treasury's reentrant prune callback.

## Scope

- In scope:
  - `src/goals/ManagedBudgetController.sol`
  - focused managed-controller regression tests
  - behavior docs only where terminalization wording becomes stale
- Out of scope:
  - changing open-preset `BudgetTCR` behavior
  - reopening the already-landed `BudgetTreasury.failRemovedBudget()` removal-finalizer behavior
  - unrelated managed-preset API cleanup

## Constraints

- Preserve the treasury callback as a best-effort path for external terminalization and retry flows.
- Keep controller-owned cleanup idempotent so direct `pruneTerminalBudget(...)` remains permissionless and safe after prior local cleanup.
- Do not regress the current removal path that already skips inline treasury-to-controller prune on `failRemovedBudget()`.

## Intended Change

1. Add a local managed-controller helper that removes ledger/recipient state, syncs the goal treasury, and deactivates topology for a terminal budget without reentering through the external prune entrypoint.
2. Reuse that helper from `removeBudget(...)`, `pruneTerminalBudget(...)`, and `syncBudgetTreasuries(...)` after successful treasury syncs that leave the budget resolved.
3. Add regressions covering controller-triggered terminalization during batch sync and direct removal/final prune idempotence expectations.

## Verification

- focused managed-controller tests
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
Completed: 2026-03-12

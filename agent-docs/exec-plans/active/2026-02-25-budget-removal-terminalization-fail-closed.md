# Budget Removal Terminalization Fail-Closed

Status: in_progress
Created: 2026-02-25
Updated: 2026-02-25

## Goal

Ensure accepted budget removals cannot complete unless the child budget treasury is terminally resolved, preventing permissionless `sync()` from restarting spend after removal.

## Scope

- In scope:
  - Make `BudgetTCR.finalizeRemovedBudget(...)` fail closed when `disableSuccessResolution` fails.
  - Require terminal resolution before marking deployment inactive and clearing pending removal.
  - Add/adjust BudgetTCR regression tests for disable-failure removal handling.
- Out of scope:
  - Changes to `BudgetTreasury` lifecycle semantics outside removal terminalization integration.
  - Any edits under `lib/**`.

## Constraints

- Preserve existing remove-request/execute-request flow in `GeneralizedTCR`.
- Keep `retryRemovedBudgetResolution(...)` permissionless semantics intact for already-inactive stacks.
- Run required Solidity verification gate: `pnpm -s verify:required`.

## Acceptance criteria

- `finalizeRemovedBudget(...)` reverts when success-resolution disabling fails.
- Removal pending flag, parent recipient, and stake-ledger mapping remain unchanged on such revert.
- Successful finalize still disables success resolution, terminalizes treasury, clears pending removal, and removes parent/ledger wiring.

## Progress log

- 2026-02-25: Confirmed fail-open path where finalize could deactivate stack while treasury remained non-terminal.
- 2026-02-25: Implemented fail-closed finalize logic + regression coverage update.

## Open risks

- Shared worktree has unrelated in-flight changes; this plan scopes only BudgetTCR removal terminalization behavior.

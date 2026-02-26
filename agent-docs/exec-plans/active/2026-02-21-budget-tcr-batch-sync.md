# Budget TCR Permissionless Batch Sync

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Add a simple permissionless batch endpoint on `BudgetTCR` to best-effort call `sync()` on multiple active budget treasuries in one transaction.

## Scope

- In scope:
  - Add `syncBudgetTreasuries(bytes32[] itemIDs)` to `IBudgetTCR` and `BudgetTCR`.
  - Per-item best-effort behavior (`try/catch`) with observable attempted/skipped events.
  - Skip non-deployed and inactive stacks without reverting the whole call.
  - Add focused tests in `test/BudgetTCR.t.sol`.
  - Update architecture/reference docs to capture the new liveness endpoint.
- Out of scope:
  - Onchain auto-trigger/callback architecture changes.
  - Economic incentives/rewards for keepers.
  - Changes under `lib/**`.

## Constraints

- Preserve existing lifecycle/security semantics for budget treasuries.
- Keep endpoint permissionless and simple.
- Preserve existing `retryRemovedBudgetResolution` semantics.
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Tasks

1. Extend `IBudgetTCR` with batch-sync events + function signature.
2. Implement `BudgetTCR.syncBudgetTreasuries` with per-item skip/attempt behavior.
3. Add tests for mixed success/failure and skip conditions.
4. Update docs (`ARCHITECTURE.md`, `agent-docs/**`) for discoverability.
5. Run required verification commands.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass, 758 tests)

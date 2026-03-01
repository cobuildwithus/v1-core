# 2026-02-25 remove-caps-paginated-ledger-finalize

Status: in_progress
Created: 2026-02-25
Updated: 2026-02-25

## Goal

- Remove hard caps (`MAX_CHILD_FLOWS`, `_MAX_TRACKED_BUDGETS`) while preserving protocol liveness by making reward-ledger settlement and per-user success-point preparation permissionless and paginated.

## Scope

- In scope:
  - Remove/neutralize child-flow and tracked-budget hard cap enforcement.
  - Introduce paginated completion path for `BudgetStakeLedger` success finalization.
  - Introduce optional paginated per-user successful-point preparation path consumed by `RewardEscrow`.
  - Keep existing small-N behavior operational without requiring mandatory pre-steps.
  - Add targeted tests for pagination and removed-cap behavior.
- Out of scope:
  - Redesign baseline/default recipient units.
  - TCR economics/governance parameter redesign.
  - Backward-compat shims for removed cap assumptions.

## Constraints

- Do not modify `lib/**`.
- Preserve security-critical lifecycle invariants:
  - Goal terminalization must not brick if escrow finalization cannot fully complete in one tx.
  - Claims must remain gated by escrow finalization.
- Keep interface and call-path changes coherent in one change set.

## Proposed Design

1. Child cap removal:
   - Set protocol `MAX_CHILD_FLOWS` constant to effectively unbounded to disable runtime add cap.
2. Tracked-budget cap removal:
   - Remove `_MAX_TRACKED_BUDGETS` revert in `BudgetStakeLedger.registerBudget`.
3. Ledger finalization pagination:
   - Convert `finalize(...)` to initialize success-finalization state (O(1) start).
   - Add permissionless `finalizeStep(uint256 maxBudgets)` to process tracked budgets in chunks.
   - Keep non-success final states one-shot.
4. User points pagination (optional):
   - Add permissionless `prepareUserSuccessfulPoints(address,uint256)` on ledger.
   - Expose prepared-point read API and allow escrow claim path to consume prepared results when present.
5. Registration freeze after terminalization:
   - Block new budget registrations once goal is resolved to prevent post-terminal tracked-set growth.

## Verification Plan

- Targeted tests:
  - Removed cap behavior in flow recipient and ledger registration tests.
  - Success finalization progresses across multiple `finalizeStep` calls and completes deterministically.
  - Optional user-point preparation path works and is consumed by claim path.
- Required gate:
  - `pnpm -s verify:required`

## Risks

- Interface expansion may require broad compile updates.
- Existing tests that assume immediate full finalization may need adaptation when success finalization is paginated.
- Any post-terminal registration assumptions in fixtures may now revert and need explicit setup ordering.


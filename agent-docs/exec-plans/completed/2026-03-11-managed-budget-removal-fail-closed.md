# Managed budget removal fail-close

Status: completed
Created: 2026-03-11
Updated: 2026-03-12

## Goal

- Prevent removed managed budgets from resuming payout through later permissionless `BudgetTreasury.sync()` calls.

## Scope

- In scope:
  - add a controller-only removal terminalization path on `BudgetTreasury`,
  - route managed activated removals through that path,
  - add regression coverage for managed removal fail-closed behavior,
  - update lifecycle docs if the managed/open removal split changes documented behavior.
- Out of scope:
  - changing open `BudgetTCR` activation-locked removal semantics in this stream,
  - edits under `lib/**`.

## Constraints

- Preserve existing pre-activation strict-failure removal behavior, even if the controller uses the dedicated removal finalizer for both funding and activated budgets.
- Keep the managed fix hard-cut and fail-closed: once removed, future `sync()` must not reopen spending.
- Do not overwrite unrelated in-flight work already present in `BudgetTreasury` / `ManagedBudgetController`.
- Run the required Solidity gates:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`

## Risks

1. A generic removal terminalization helper could accidentally be reused on open budgets and change slash behavior.
   Mitigation: keep the new entrypoint explicitly controller-only and only wire it from `ManagedBudgetController` in this stream.
2. Managed docs currently describe activated removals as unresolved normal lifecycle.
   Mitigation: update architecture/spec text in the same change set.

## Tasks

1. Add a removal-specific controller entrypoint on `IBudgetTreasury` / `BudgetTreasury`.
2. Switch managed activated removal flow to the new terminalization call.
3. Replace managed tests that expect unresolved post-removal active state with fail-closed assertions.
4. Update relevant lifecycle docs for the managed-specific behavior split.
5. Run required verification, then completion workflow passes.

## Decisions

- Managed removals will now terminalize immediately to `Failed` through a dedicated controller-only path.
- Managed removals now use that dedicated controller-only finalizer for both funding and activated budgets so the controller can finish parent detach + goal sync in one path.
- `BudgetTreasury.failRemovedBudget()` skips only the inline controller-prune callback during that finalize call; permissionless `retryTerminalSideEffects()` still attempts the normal prune/sync side-effect set later if needed.
- Open `BudgetTCR` activation-locked removals remain unchanged for now because they intentionally interact with premium/slash semantics.

## Progress notes

- Implemented `IBudgetTreasury.failRemovedBudget()` and wired `ManagedBudgetController.removeBudget(...)` through it.
- Added targeted treasury tests plus managed-controller unit and real-stack coverage asserting later `sync()` calls remain terminal no-ops after removal.
- Added a real-stack regression covering the deferred managed-removal repair path: inline goal-sync failure during `removeBudget(...)`, followed by permissionless `retryTerminalSideEffects()` successfully repairing prune/sync after the controller has already marked the stack inactive.
- Applied a simplify-pass cleanup by narrowing `BudgetTreasury`'s pruning dependency to a local one-method interface instead of the full controller surface.
- Follow-up cleanup closes the deferred managed-removal side-effect gap: controller-owned removals now best-effort sync the goal treasury inline, and `failRemovedBudget()` suppresses the guaranteed self-reentrant prune callback during that removal finalization while leaving retry-based repair available.
- `pnpm -s lint:solidity:warnings` passes.
- `pnpm -s verify:required` was originally blocked by unrelated property test `test/flows/FlowLedgerChildSyncProperties.t.sol::testFuzz_allocate_stakeVaultResolved_childCommitNonZero_changedStake_stillCheckpointsAndSyncs`.
- 2026-03-12 cleanup pass tightened that stale fuzz bound to require a real effective-weight change, reran `pnpm -s verify:required`, and the shared required gate passed.
- 2026-03-12 completion workflow finished cleanly:
  - simplify pass reported no further behavior-preserving cleanup,
  - coverage audit added extra real-stack assertions that managed controller-owned terminal sync clears the ledger recipient mapping immediately,
  - final review reported no correctness or security findings in the retained scope.
- Coverage audit added `test_removeBudget_preActivation_usesStrictFailurePathWithoutFailRemovedBudget` and committed it as `f3f3093`; this follow-up updates that expectation to the unified removal-finalizer path.

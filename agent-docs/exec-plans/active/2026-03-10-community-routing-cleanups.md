# Community Routing Cleanups

## Goal

Apply behavior-preserving cleanup to the community goal registry and split hook by removing redundant stored state and outdated aliasing.

## Why

- `CommunityGoalRegistry` already treats `bytes32(goalId)` as the canonical item id, so persisting `GoalListing.itemId` duplicates derivable state.
- Listed membership already comes from `_listedGoalIndexPlusOne`, so storing a second `exists` boolean is unnecessary.
- `CobuildSplitHook.approvedGoals()` is an outdated alias for registry selectability and should use the current terminology directly.
- Historical-route terminal checks duplicate selectability filtering already enforced by `CommunityGoalRegistry`.

## Scope

- Derive community-goal listing item ids from `goalId` on read/emit.
- Derive listing existence from `_listedGoalIndexPlusOne`.
- Rename the split-hook/public interface getter from `approvedGoals()` to `selectableGoalIds()`.
- Remove redundant terminal-presence filtering from `CobuildSplitHook._historicalRoute()`.
- Update impacted tests and mocks.

## Constraints

- Preserve current uncommitted goal-deployment-registry cutover edits in the same files.
- Do not implement the separate planned historical-volume naming cleanup claimed in the ledger.
- Keep behavior unchanged for routing, selectability, and event semantics aside from the interface rename.

## Risks

- Shared-file overlap in `CobuildSplitHook` and its tests with other active cleanup rows.
- Interface rename can break test mocks or downstream compile sites if any call site is missed.

## Verification

- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

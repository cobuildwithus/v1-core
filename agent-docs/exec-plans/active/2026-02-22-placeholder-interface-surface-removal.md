# Placeholder Interface Surface Removal

## Goal
Remove dead/placeholder external interface surface that exists only as a deprecated revert/no-op path.

## Scope
- Remove `setCobuildRevnetId(uint256)` from `src/interfaces/IGoalTreasury.sol`.
- Remove the corresponding reverting implementation from `src/goals/GoalTreasury.sol`.
- Remove now-dead related interface declarations tied only to that removed surface.
- Update tests/docs that reference the removed surface.

## Constraints
- Do not modify `lib/**`.
- Keep `cobuildRevnetId` behavior unchanged (immutable value seeded from `goalRevnetId`).
- Preserve existing burn/sweep behavior.

## Acceptance criteria
- No deprecated revert-only setter remains on `IGoalTreasury`/`GoalTreasury`.
- No stale tests/docs reference that removed setter surface.
- Verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress log
- 2026-02-22: Plan created.
- 2026-02-22: Removed `setCobuildRevnetId` from `IGoalTreasury` and `GoalTreasury`.
- 2026-02-22: Removed dead interface symbols tied to setter-only compatibility (`INVALID_COBUILD_REVNET_ID`, `COBUILD_REVNET_ID_IMMUTABLE`, `CobuildRevnetIdUpdated`).
- 2026-02-22: Updated `GoalTreasury` unit tests and architecture/spec docs to reflect immutable cobuild revnet behavior.
- 2026-02-22: Simplified `GoalTreasury` by deriving `cobuildRevnetId()` from `goalRevnetId` instead of storing duplicate immutable state.

## Open risks
- Interface removal is a breaking ABI change for downstream consumers compiled against the old method.

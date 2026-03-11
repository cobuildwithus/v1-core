# Goal Deployment Registry Cutover

## Goal

Hard-cut community routing so canonical `goalId -> goalTreasury` ownership comes from a protocol deployment registry instead of `CommunityGoalRegistry` item payload/state.

## Why

- Historical/default community routing currently keys demand by stable `goalId` but resolves beneficiary sink from mutable registry listing data.
- Registry treasury validation is self-attested (`goalRevnetId()`), which is not sufficient for a privileged beneficiary sink.
- A protocol-owned deployment registry supports multiple `GoalFactory` versions over time without giving TCR payloads control over treasury resolution.

## Scope

- Add a protocol-owned goal deployment registry contract/interface.
- Register newly deployed goals from `GoalFactory`.
- Remove `goalTreasury` from community-goal item data and registry storage.
- Point `CobuildSplitHook` default/raw routing at the deployment registry’s canonical treasury lookup.
- Update tests and durable docs for the cutover.

## Constraints

- Preserve existing active worktree changes in `GoalFactory`, `CommunityGoalRegistry`, and `CobuildSplitHook`.
- Keep `CommunityGoalRegistry` responsible only for listing/selectability/metadata.
- Prefer hard cutover over backward-compat shims because repo policy says no live deployments exist.

## Risks

- Multi-file interface change across registry, hook, factory, and tests.
- Existing hook/registry active entries already modified some of the same files; edits must be merged carefully.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

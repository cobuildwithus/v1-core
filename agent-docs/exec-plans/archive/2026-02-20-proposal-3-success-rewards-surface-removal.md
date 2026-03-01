# Proposal 3: Success Reward Pending/Grace Surface Removal

## Goal
Remove the unused success-reward pending/grace scaffolding so goal success has a single path: `resolveSuccess` finalizes reward escrow inline.

## Scope
- Remove pending/grace interface surface from `src/interfaces/IGoalTreasury.sol`.
- Remove pending/grace state and methods from `src/goals/GoalTreasury.sol`.
- Update tests that depended on removed API.
- Update architecture/reference docs that still described grace/pending behavior.

## Constraints
- Do not modify `lib/**`.
- Preserve existing success/failure/expiry terminalization behavior outside the removed surface.
- Keep rewards snapshot cutoff anchored to `successAt`.

## Acceptance criteria
- `IGoalTreasury` no longer exposes pending/grace errors, events, or getters.
- `GoalTreasury` no longer stores grace state or exposes pending/readiness/finalize helper methods.
- Goal success still finalizes escrow immediately when configured.
- Verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress log
- 2026-02-20: Removed pending/grace symbols from `IGoalTreasury` and `GoalTreasury`.
- 2026-02-20: Updated `GoalTreasury` and `RewardEscrowIntegration` tests to align with immediate-only finalize flow.
- 2026-02-20: Updated `ARCHITECTURE.md`, `agent-docs/cobuild-protocol-architecture.md`, and `agent-docs/references/goal-funding-and-reward-map.md`.

## Open risks
- Interface change is breaking for consumers compiled against removed methods/events.
- Existing off-chain indexers may need to adjust for the updated `SuccessRewardsFinalized` event signature.

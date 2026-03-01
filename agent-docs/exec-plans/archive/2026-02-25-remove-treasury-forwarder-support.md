# Remove Treasury Forwarder Support

Status: completed
Created: 2026-02-25
Updated: 2026-02-25

## Goal

- Remove `budgetTreasury()` forwarder compatibility from protocol runtime surfaces.
- Make `GoalStakeVault` read treasury lifecycle/authority directly from `goalTreasury`.

## Scope

- In scope:
  - `src/goals/GoalStakeVault.sol`
  - `src/interfaces/ITreasuryForwarder.sol` (remove)
  - `src/library/TreasuryResolver.sol` (remove)
  - Forwarder-specific tests in `test/goals/GoalStakeVault.t.sol` and `test/goals/TreasuryResolver.t.sol`
  - Architecture docs mentioning one-hop forwarder resolution
- Out of scope:
  - Budget stack lifecycle redesign
  - Any changes under `lib/**`

## Success criteria

- No production code path depends on `budgetTreasury()` forwarding.
- `GoalStakeVault` authorization/resolution behavior is direct-treasury-only and tests reflect that policy.
- Required verification gate passes (`pnpm -s verify:required`).
- Completion workflow passes run (`simplify` -> `test-coverage-audit` -> `task-finish-review`).

## Notes

- Worktree is already dirty; do not revert unrelated changes.

## Verification

- `forge build -q` (pass)
- `forge test -q --match-path test/goals/GoalStakeVault.t.sol` (pass)
- `pnpm -s verify:required` (fails in unrelated suites:
  - `test/GeneralizedTCREvidenceTimeout.t.sol::test_timeout_clears_mapping_and_old_dispute_cannot_affect_new_request` (flaky expectation mismatch; passed on isolated rerun),
  - `test/goals/RewardEscrowIntegration.t.sol::test_success_claimsFollowCheckpointPoints_withMixedStakeTypes_andStreamFunding` (existing snapshot assertion mismatch outside this scope))

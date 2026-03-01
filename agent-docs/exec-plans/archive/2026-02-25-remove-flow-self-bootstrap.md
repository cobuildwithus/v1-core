# 2026-02-25 remove-flow-self-bootstrap

Status: completed
Created: 2026-02-25
Updated: 2026-02-25

## Goal

- Remove Flow self-unit/self-connect bootstrap behavior while preserving liveness by best-effort refreshing outflow when distribution pool units transition from zero to non-zero.

## Scope

- In scope:
  - Remove init-time self unit seeding and self pool connection.
  - Remove self-unit floor revert path.
  - Add best-effort outflow refresh trigger on recipient bootstrap paths (`addRecipient`, `bulkAddRecipients`, `addFlowRecipient`) for `0 -> >0` total unit transitions.
  - Add observability for failed best-effort refresh attempts.
  - Update flow tests for new connectivity/bootstrap semantics.
- Out of scope:
  - Changes under `lib/**`.
  - Redesign of outflow-cap math or treasury lifecycle policy.

## Constraints

- Preserve no-loss behavior when distribution pool has zero units.
- Do not brick recipient add paths if refresh write fails.
- Keep removal a hard cutover (no legacy compatibility shim).
- Required verification gate: `pnpm -s verify:required`.

## Proposed Design

1. Remove self bootstrap:
   - Delete self-unit constant and init writes in `Flow.__Flow_initWithRoles`.
2. Remove self-unit floor enforcement:
   - Delete `SELF_UNITS_MUST_REMAIN_POSITIVE` guard from `FlowPools.updateDistributionMemberUnits`.
3. Add best-effort refresh path:
   - Detect distribution pool total unit transition `0 -> >0` around recipient bootstrap writes.
   - If current target outflow is positive, attempt a self-call refresh that reapplies `_setFlowRate(cachedTarget)`.
   - Catch and emit a failure event instead of reverting.
4. Tests:
   - Init-time flow should no longer be connected to own pool.
   - Self-unit clearing should no longer revert.
   - Regression: setting target with zero units stays non-distributing until first recipient bootstrap, then refresh resumes distribution.

## Verification Plan

- Run focused flow tests while iterating.
- Run required gate: `pnpm -s verify:required`.
- Run completion workflow passes before handoff.

## Risks

- Added self-call refresh helper introduces a new internal operational pathway; must be strictly self-call gated.
- Existing tests may implicitly assume self-connected behavior in max-safe/outflow assertions.

## Coverage Audit Pass (2026-02-25)

### Highest-impact gaps addressed

- Added parent-authorized retry coverage for `refreshTargetOutflowRate()` to ensure the new operator/parent fallback entrypoint is usable by parent flows after bootstrap refresh failure.
- Added zero-target bootstrap guard coverage to ensure `addRecipient` does not attempt a refresh when cached target outflow is `0`, preventing unnecessary host writes/failure events.
- Added non-bootstrap transition guard coverage to ensure `addRecipient` does not reattempt best-effort refresh once distribution units are already non-zero.

### Tests added

- `test_addRecipient_zeroToNonZeroUnits_withZeroCachedTarget_skipsRefreshAttempt`
- `test_addRecipient_nonBootstrapTransition_skipsRefreshAttempt`
- `test_refreshTargetOutflowRate_allowsParentCaller`

### Verification run (narrow scope)

- `forge test --match-path test/flows/FlowRates.t.sol --match-test "test_(addRecipient_zeroToNonZeroUnits_withZeroCachedTarget_skipsRefreshAttempt|addRecipient_nonBootstrapTransition_skipsRefreshAttempt|refreshTargetOutflowRate_allowsParentCaller)"` (pass: 3/3)
- `forge test --match-path test/flows/FlowRates.t.sol` (pass: 32/32)

### Remaining recommendations (priority)

1. None in-scope after follow-up test additions.

## Completion Notes (2026-02-25)

- Follow-up coverage was added for non-bootstrap/zero-target guard paths on `bulkAddRecipients` and `addFlowRecipient`.
- Refresh-failure tests now assert `TargetOutflowRefreshFailed` payload values (cached target + revert reason), not only event presence.
- Focused verification after follow-up changes:
  - `forge test --match-path test/flows/FlowRates.t.sol` (pass: 36/36)
  - `forge test --match-path test/flows/FlowInitializationAndAccessConnect.t.sol` (pass: 1/1)
  - `forge test --match-path test/flows/FlowAllocationsMathEdge.t.sol` (pass: 6/6)
- Broad `pnpm -s verify:required` currently fails due unrelated in-flight goal/revnet integration tests in the shared worktree (`GoalRevnetIntegration*`, `RewardEscrowIntegration*`) and not from this Flow self-bootstrap slice.

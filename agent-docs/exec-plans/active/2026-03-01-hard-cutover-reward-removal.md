# 2026-03-01 Hard Cutover Reward Removal

## Goal

Remove the legacy goal-success reward escrow/points model and complete underwriting hard cutover:
- incentives = budget premium + underwriter slashing,
- goal terminal leftovers = burn-only,
- strict budget removal terminalization,
- no backward-compatibility shims.

## Scope

- Remove reward escrow contracts/interfaces/math and all runtime wiring.
- Remove goal success settlement split-to-escrow plumbing.
- Expose `budgetStakeLedger` directly from `GoalTreasury` and rewire dependents.
- Convert `BudgetStakeLedger` to coverage-only accounting (no points/finalization snapshot claim prep).
- Keep PremiumEscrow/UnderwriterSlasherRouter and juror slashing behavior unchanged.

## Constraints

- Hard cutover only (no live deployments).
- Do not touch `lib/**`.
- Keep tree compiling through each chunked change set.

## Execution Plan

1. Interface + event surface cutover (`IGoalTreasury`, hook split outputs, deployment params).
2. `GoalTreasury` burn-only settlement + remove reward-escrow terminal hooks.
3. Delete `RewardEscrow`/`IRewardEscrow`/`RewardEscrowMath`.
4. Simplify `BudgetStakeLedger` + `IBudgetStakeLedger` to coverage-only.
5. Rewire `BudgetTCR`, `ERC20VotesArbitrator`, factory/deploy paths to direct treasury ledger lookup.
6. Enforce strict removed-budget terminalization path (no reward-history lock branch).
7. Update tests/mocks/scripts/docs to new surfaces.
8. Run required verification and completion workflow passes.

## Verification

- Required gate: `pnpm -s verify:required`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

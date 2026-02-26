# Goal Min-Raise Balance Gating

## Objective
- Remove reliance on entrypoint-only accounting for goal lifecycle transitions.
- Treat treasury flow balance as the source of truth for min-raise checks so direct SuperToken transfers cannot strand funds in funding state.

## Scope
- `src/goals/GoalTreasury.sol`
- `test/goals/GoalTreasury.t.sol`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/index.md`

## Plan
1. Switch `GoalTreasury` min-raise lifecycle gates from `totalRaised` to live `treasuryBalance()`.
2. Keep `totalRaised` as telemetry/event accounting only (no state-machine gating).
3. Update goal treasury tests to encode new activation/expiry behavior.
4. Update architecture/reference docs to reflect the new invariant and refresh index verification dates.
5. Run `forge build -q` and `pnpm -s test:lite`.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

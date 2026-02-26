# 2026-02-24 goal-linear-spend-pattern-safety-cap

## Objective
- Fix goal spend-down insolvency risk where `targetFlowRate = balance / remaining` can set a rate that later liquidates before deadline.
- Keep current behavior linear by default, while introducing a small pattern abstraction to support future spend patterns.
- Reuse existing treasury sync safety helpers instead of duplicating fallback logic.

## Scope
- `src/goals/GoalTreasury.sol`
- `src/goals/library/TreasuryFlowRateSync.sol`
- `src/goals/library/GoalSpendPatterns.sol` (new)
- `test/goals/GoalTreasury.t.sol`
- docs updates for goal lifecycle flow-rate policy

## Constraints
- Do not modify `lib/**`.
- Preserve existing goal terminalization/fallback semantics.
- Avoid proactive inflow max-safe capping for goal targets unless required by write-fallback paths (keep spend-down invariant split).

## Plan
1. Add a dedicated goal spend-pattern library with a pattern enum and linear implementation.
2. Route `GoalTreasury.targetFlowRate()` through the pattern library (linear pattern locked for now).
3. Add a new treasury sync helper that pre-caps linear spend-down target by a buffer-aware liquidation horizon derived from existing buffer-constrained-rate helper.
4. Keep existing apply/fallback ladder behavior for write failures.
5. Add regression tests showing near-deadline proactive cap of the linear target and no regression of existing fallback behavior.
6. Update docs and run required verification gate.

## Verification
- `pnpm -s verify:required`

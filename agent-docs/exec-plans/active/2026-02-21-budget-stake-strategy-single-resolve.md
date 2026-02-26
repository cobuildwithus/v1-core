# Budget Stake Strategy Single-Resolve Cleanup

## Goal
Eliminate duplicate `TreasuryResolver.resolve(...)` calls inside `BudgetStakeStrategy` read paths by resolving once per call and reusing the same effective treasury address for both closure checks and ledger weight reads.

## Scope
- `src/allocation-strategies/BudgetStakeStrategy.sol`
- `test/goals/BudgetStakeStrategy.t.sol`

## Invariants to Preserve
- Fail-closed behavior remains unchanged when treasury code is missing or `resolved()` probe fails.
- Forwarded treasury anchors (via `budgetTreasury()`) still resolve correctly.
- Allocation permissions/weights remain zeroed when budget is terminally resolved.

## Validation
- `forge test --match-path test/goals/BudgetStakeStrategy.t.sol`
- `forge build -q`
- `pnpm -s test:lite`

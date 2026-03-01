# Helper View Pack (High-Value, Additive)

## Goal
Add high-value helper view functions that reduce multi-call joins and offchain recomputation for clients, while keeping runtime behavior unchanged.

## Scope
- Goals/reward surfaces:
  - `src/interfaces/IRewardEscrow.sol`, `src/goals/RewardEscrow.sol`
  - `src/interfaces/IBudgetStakeLedger.sol`, `src/goals/BudgetStakeLedger.sol`
  - `src/interfaces/IGoalTreasury.sol`, `src/goals/GoalTreasury.sol`
  - `src/interfaces/IBudgetTreasury.sol`, `src/goals/BudgetTreasury.sol`
- TCR/arbitrator read surfaces:
  - `src/tcr/interfaces/IGeneralizedTCR.sol`, `src/tcr/GeneralizedTCR.sol`
  - `src/tcr/interfaces/IERC20VotesArbitrator.sol`, `src/tcr/ERC20VotesArbitrator.sol`
  - related test mocks if interface additions require it.

## Invariants to Preserve
- No state-machine/funds-flow/access-control behavior changes.
- Views remain deterministic for current block and never mutate state.
- New read APIs are additive/backward-compatible.

## Planned Additions
1. RewardEscrow: claim preview + account claim cursor views.
2. BudgetStakeLedger: budget metadata/checkpoint views + paginated tracked budget summaries.
3. Goal/Budget treasury: lifecycle status bundle views.
4. GeneralizedTCR: latest-request index, request snapshot, request state helper.
5. ERC20VotesArbitrator: round/voter status helper views.

## Validation
- `forge build -q`
- `pnpm -s test:lite`
- plus focused tests for new helper views where practical.

## Notes
- Repository currently has unrelated dirty-tree changes; avoid reverting non-task edits.

# 2026-03-04 Buyback + V4 Hook Deployer Plan

## Goal
Implement production launch defaults for revnet buyback configuration (COBUILD quote token, 0.3% fee tier, 1h TWAP) and add a Uniswap v4 routed hook contract for GOAL/COBUILD pools with best-route selection across JB/v3/v4.

## Scope
- `src/goals/GoalFactory.sol`
- `src/goals/library/GoalFactoryRevnetDeploy.sol`
- `src/hooks/CobuildRoutedV4Hook.sol`
- `src/interfaces/external/uniswap-v3/**`
- `test/goals/GoalFactoryRevnetDeploy.t.sol`
- `test/hooks/CobuildRoutedV4Hook.t.sol`

## Constraints
- Do not modify `lib/**`.
- Preserve existing constructor validation and goal deploy invariants.
- Keep v4 hook exact-input only and fail-closed for invalid pair/terminal assumptions.
- Maintain strict allowance hygiene around external token spends.

## Plan
1. Patch buyback defaults + pool token selection in factory deploy path.
2. Add regression test around deployer payload values.
3. Implement v4 routed hook + required v3 interfaces.
4. Add targeted hook unit tests for route-selection/slippage decode and pair validation.
5. Run required verification and completion workflow passes.

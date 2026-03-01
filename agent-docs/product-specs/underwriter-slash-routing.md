# Underwriter Slash Routing (Addendum)

This note supplements the underwriter slash recycle path invariants.

## Async Reserved Routing

- Router-side immediate forwarding is opportunistic:
  - `UnderwriterSlasherRouter.slashUnderwriter(...)` can successfully call revnet `pay(...)` and still observe `convertedGoalAmount == 0` in that transaction.
  - This is acceptable when conversion value is settled asynchronously through reserved-token routing rather than immediate router-side goal ERC20 minting.
- Operational expectation:
  - delayed goal-token settlement that reaches the router must be forwardable with `retryForwarding()`.
  - conversion-call failures remain observable via existing conversion failure events.

## Regression Coverage

- `test/goals/UnderwriterSlasherRouterAsyncReservedRouting.t.sol`
  - `test_slashUnderwriter_allowsAsyncReservedRouting_whenImmediateGoalMintIsZero`

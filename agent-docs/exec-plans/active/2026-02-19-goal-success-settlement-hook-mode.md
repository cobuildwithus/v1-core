# Goal Revnet Split Hook Success Settlement Mode

## Objective
- Keep the reserved-token split hook active through goal success settlement without adding another ruleset.
- Route each reserved split amount to reward escrow and burn the complement with no remainder path.
- Remove owner-controlled hook transitions and derive behavior directly from treasury state/minting status.

## Scope
- `src/hooks/GoalRevnetSplitHook.sol`
- `test/goals/GoalRevnetSplitHook.t.sol`

## Design Notes
- Constructor config carries immutable `settlementRewardEscrowBps`.
- `processSplitWith` is permissionless and state-derived:
  - if `canAcceptHookFunding`, execute funding path
  - else if treasury state is `Succeeded` and minting is open, execute settlement split + burn path
  - otherwise revert non-zero processing
- No owner transitions (`enter/close`) are required.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

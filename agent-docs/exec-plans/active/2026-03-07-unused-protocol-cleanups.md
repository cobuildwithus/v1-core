# Unused Protocol Cleanups

## Goal

Remove the approved unused runtime surface discovered during dead-code review without changing intended protocol behavior.

## Scope

- Remove duplicate `GoalRevnetSplitHook` storage for `flow` and `superToken` while preserving derived getters.
- Remove unused 2-argument `BudgetTCRDeployer.initialize` overload and matching interface declaration.
- Remove unused `CobuildRoutedV4Hook.V3_POOL_NOT_FOUND` error.
- Remove dead unit-seeding branch from `FlowPools.connectAndInitializeFlowRecipient`, rename the helper to reflect its remaining behavior, and simplify its caller.
- Update impacted tests to reflect the removed `BudgetTCRDeployer` initializer overload.

## Constraints

- Do not touch `lib/**`.
- Keep changes behavior-preserving aside from the explicitly removed ABI surface.
- Run required Solidity verification/lint gates before handoff.
- Run completion workflow passes because this is a non-trivial Solidity change.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

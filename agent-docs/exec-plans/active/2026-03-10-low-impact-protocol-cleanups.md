# Low-Impact Protocol Cleanups

## Goal

Validate and apply behavior-preserving low-impact protocol simplifications where the current abstractions no longer carry distinct meaning.

## Scope

- Inline `GoalTreasury._raisedForLifecycle()` into its call sites if it is still just `treasuryBalance()`.
- Remove `FlowPools.removeFromPools()` if it remains a one-line zero-unit wrapper over `updateDistributionMemberUnits(...)`.
- Remove `GoalTreasury.recordHookFunding(...)` if production usage analysis still shows the real hook path goes through `processHookSplit(...)` only, and migrate affected tests onto that real hook-split path.

## Constraints

- Do not touch `lib/**`.
- Preserve goal lifecycle/min-raise behavior and flow recipient removal semantics.
- Keep lifecycle and funding behavior unchanged while deleting the dead `recordHookFunding(...)` interface/implementation surface and any stale doc references to it.
- Run required Solidity verification/lint gates before handoff.
- Run completion workflow passes because this touches Solidity production code.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

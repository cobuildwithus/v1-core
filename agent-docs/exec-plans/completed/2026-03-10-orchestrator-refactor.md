# Orchestrator Refactor

## Goal

Refactor `CobuildSplitHook.processSplitWith(...)` and `RoundFactory.createRoundForBudget(...)` into thinner orchestrators with clearer validation/resolution helpers and isolated effectful phases, without changing runtime behavior.

## Scope

- `src/hooks/CobuildSplitHook.sol`
- `src/rounds/RoundFactory.sol`
- `test/hooks/CobuildSplitHook.t.sol`
- `test/rounds/RoundFactory.t.sol`

## Constraints

- Do not change public interfaces, emitted events, or routing/deployment semantics.
- Keep community-routing invariants intact: explicit-route-only historical signal, same-transaction pending-route consumption, direct-pay backlog deferral.
- Keep round deployment invariants intact: budget/goal/stake-vault context resolution, super-token underlying compatibility, non-slashing arbitrator wiring.
- Avoid touching `lib/**`.
- Run required Solidity verification/lint gates and completion workflow before handoff.

## Verification

- Targeted `forge test` for `CobuildSplitHook` and `RoundFactory`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
Status: completed
Updated: 2026-03-10
Completed: 2026-03-10

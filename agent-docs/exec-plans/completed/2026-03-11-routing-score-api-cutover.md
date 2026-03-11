# Routing Score API Cutover

## Goal

Rename community-routing telemetry from misleading observed-volume wording to routing-score wording, remove the duplicate total getter now that both getters expose the same decayed selectable mass, and prune the dead season-decay branch.

## Scope

- `src/interfaces/ICobuildSplitHook.sol`
- `src/hooks/CobuildSplitHook.sol`
- `test/hooks/CobuildSplitHook.t.sol`
- `test/hooks/CobuildSplitHookGas.t.sol`
- `test/juicebox/CobuildCommunityTerminal.t.sol`
- `test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/references/module-boundary-map.md`

## Constraints

- Hard cutover is acceptable because there are no live deployments yet.
- Respect the existing in-flight season-based decay changes in `CobuildSplitHook.sol`; do not revert or restage unrelated edits.
- Keep backlog routing behavior, selectability gating, and controller-only callback constraints unchanged.
- Do not touch `lib/**`.

## Success Criteria

- `ICobuildSplitHook` and `CobuildSplitHook` expose routing-score terminology instead of observed-volume terminology.
- Only one total getter remains for current selectable decayed routing mass.
- `_decayedRoutingScore()` no longer carries the redundant `seasonsElapsed == 0` branch.
- Tests and docs consistently describe the values as routing scores / routing mass rather than historical raw volume.
- Required Solidity verification and completion workflow passes are green.

## References

- `agent-docs/exec-plans/completed/2026-03-11-community-routing-decay-and-prune.md`
- `agent-docs/exec-plans/completed/2026-03-11-routing-season-decay-and-terminal-relist-guard.md`

## Progress Log

- 2026-03-11: Read routing architecture/process docs, inspected the in-flight season-decay edits, and scoped the hard-cut API rename plus duplicate-getter removal.
- 2026-03-11: Renamed the hook/interface API to `routingScoreOf` and `currentRoutingMass`, removed `currentHistoricalTotalVolume`, renamed the routing-score event, and deleted the dead `_decayedRoutingScore()` branch.
- 2026-03-11: Updated hook/community-terminal tests and canonical docs to the routing-score terminology hard cutover.
- 2026-03-11: Simplify pass suggested removing leftover tuple plumbing behind `currentRoutingMass()` and finishing two stale observed-history names; both cleanups were applied.
- 2026-03-11: Coverage audit reported no meaningful high-impact gaps; only low-priority optional assertions remain around the renamed event and gas harness total-mass read.
- 2026-03-11: Final completion review reported no findings in scope.
- 2026-03-11: Verification results:
  - `forge test --match-path test/hooks/CobuildSplitHook.t.sol` PASS
  - `forge test --match-path test/juicebox/CobuildCommunityTerminal.t.sol` PASS
  - `forge test --match-path test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol` PASS
  - `pnpm -s verify:required` PASS
  - `pnpm -s lint:solidity:warnings` PASS

## Risks

- ABI-breaking selector changes will require all local mocks/tests/callers to update in the same change set.
- Doc wording must stay aligned with decayed-score semantics so future cleanups do not reintroduce “historical volume” assumptions.
Status: completed
Updated: 2026-03-11
Completed: 2026-03-11

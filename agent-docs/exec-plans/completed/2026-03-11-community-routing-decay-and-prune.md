# Community Routing Decay And Prune

## Goal

Harden community routing so selectable goals are gated by live treasury hook-funding acceptance, historical routing uses lazy decaying explicit-route memory instead of lifetime accumulation, and terminal goals can be permissionlessly pruned from the registry.

## Scope

- `src/tcr/interfaces/ICommunityGoalRegistry.sol`
- `src/tcr/CommunityGoalRegistry.sol`
- `src/hooks/CobuildSplitHook.sol`
- `test/tcr/CommunityGoalRegistry.t.sol`
- `test/hooks/CobuildSplitHook.t.sol`
- `test/hooks/CobuildSplitHookGas.t.sol`
- `test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
- Matching canonical docs in `ARCHITECTURE.md` and `agent-docs/**`

## Constraints

- Do not touch `lib/**`.
- Keep registry listing and selectability separate.
- Use `IGoalTreasury.canAcceptHookFunding()` as the live routing gate.
- Keep backlog routing permissionless and paginated.
- Avoid hook-side prune/storage cleanup beyond correctness-critical changes.
- Respect existing unrelated worktree edits.

## Acceptance criteria

- `CommunityGoalRegistry.isSelectable/selectableGoalIds` only include listed goals whose treasury can currently accept hook funding.
- `CommunityGoalRegistry.pruneTerminalGoal(goalId)` permissionlessly delists only prunable goals and preserves canonical goal registry wiring.
- `CobuildSplitHook.observedVolumeOf(goalId)` returns a lazy decayed routing score with a fixed half-life, and historical backlog routing derives from those decayed scores.
- `CobuildSplitHook.cumulativeObservedVolume()` reflects the current decayed selectable-route total rather than lifetime cumulative telemetry.
- Unit/integration tests cover liveness gating, terminal pruning, score decay, and backlog routing behavior under decay.
- Required Solidity verification and completion workflow passes are green.

## Progress log

- 2026-03-11: Read repo routing docs, Solidity/process guidance, current registry/hook implementations, and existing hook/registry/integration tests.
- 2026-03-11: Identified required surface changes in registry interface/implementation, hook storage/events/read paths, gas/unit/integration tests, and canonical docs.
- 2026-03-11: Implemented registry liveness gating via `canAcceptHookFunding()`, permissionless terminal/broken-goal pruning, lazy decaying hook routing scores, and matching doc updates.
- 2026-03-11: Added/updated focused regression coverage for treasury liveness gating, prune success/revert cases, score decay, score refresh after decay, decayed backlog routing, broken-treasury prune, and fully decayed backlog retention.
- 2026-03-11: Verification passed:
  - `forge test --match-path test/tcr/CommunityGoalRegistry.t.sol`
  - `forge test --match-path test/hooks/CobuildSplitHook.t.sol`
  - `forge test --match-path test/hooks/CobuildSplitHookGas.t.sol`
  - `forge test --match-path test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `bash scripts/check-agent-docs-drift.sh`
- 2026-03-11: Completion workflow simplify/coverage/final-audit subagent passes were attempted; simplify/final-audit subagents timed out, so the final simplify/review pass was completed locally after reviewing the resulting diffs and rerunning required verification.

## Open risks

- The decayed-score change alters external semantics of `cumulativeObservedVolume()` and any tests or integrations assuming lifetime totals.
- Gas-profile fixture writes directly into storage slots; slot assumptions must be updated if hook storage layout changes.
- Registry pruning must stay conservative: terminal or broken-deployment cases only, without making transient read failures silently deletable.
Status: completed
Updated: 2026-03-11
Completed: 2026-03-11

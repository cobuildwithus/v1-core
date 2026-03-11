# Ownerless Community Routing Hard Cut

## Status

Completed on 2026-03-11.

## Goal

Remove the privileged system-goal and registry-owner model from community routing, make community goal curation purely TCR-based, and allow `GoalFactory.deployGoalForCommunity(...)` to be permissionless while keeping community bootstrap auth anchored to the community project owner.

## Success Criteria

- `CommunityGoalRegistry` has no owner, no pause/unpause path, and no system-goal surface.
- `CobuildSplitHook` routes only explicit user-selected routes and historical backlog across normal selectable goals with no system-floor carveout.
- `GoalFactory.deployGoalForCommunity(...)` is permissionless.
- Community terminal registration/factory deployment no longer depend on `registry.owner()` and instead authenticate against the community project owner.
- Tests/docs reflect the ownerless/TCR-only model on top of the renamed terminal files.

## Scope

- `src/tcr/CommunityGoalRegistry.sol`
- `src/tcr/interfaces/ICommunityGoalRegistry.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/juicebox/CobuildCommunityTerminal.sol`
- `src/juicebox/CobuildCommunityTerminalFactory.sol`
- `src/goals/GoalFactory.sol`
- `test/tcr/CommunityGoalRegistry.t.sol`
- `test/hooks/CobuildSplitHook.t.sol`
- `test/hooks/CobuildSplitHookGas.t.sol`
- `test/juicebox/CobuildCommunityTerminal.t.sol`
- `test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
- `test/juicebox/CobuildCommunityTerminalFactory.t.sol`
- Matching canonical docs under `ARCHITECTURE.md` and `agent-docs/**`

## Constraints

- Build on top of the current renamed-terminal head; do not revert or restage unrelated worktree edits.
- Hard cutover is acceptable because there are no live deployments yet.
- Keep community-routing legitimacy TCR-gated; goal deployment may be open, but split-hook routing must remain selectable-goal only.
- Do not touch `lib/**`.

## Design Notes

- Community bootstrap auth should move from `registry.owner()` to `DIRECTORY.PROJECTS().ownerOf(communityRevnetId)`.
- `CobuildCommunityTerminalFactory.deployFor(...)` can stay externally callable because the terminal registration signature remains the true bootstrap authorization.
- Direct goal funding remains independent from TCR listing; TCR only gates community-root routing.

## Verification

- Focused Forge suites for registry, hook, and community-terminal flows.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

### Results

- `forge test --match-path test/tcr/CommunityGoalRegistry.t.sol` PASS
- `forge test --match-path test/hooks/CobuildSplitHook.t.sol` PASS
- `forge test --match-path test/juicebox/CobuildCommunityTerminal.t.sol` PASS
- `forge test --match-path test/juicebox/CobuildCommunityTerminalFactory.t.sol` PASS
- `forge test --match-path test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol` PASS
- `forge test --match-path test/goals/GoalFactorySpendPolicyDeploy.t.sol` PASS
- `forge test --match-path test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol` PASS
- `pnpm -s verify:required` PASS
- `pnpm -s lint:solidity:warnings` PASS
- Completion-workflow subagent attempts timed out in this environment; final simplify / coverage / completion audit was completed locally with no additional code changes required beyond pruning one dead registry helper/error.

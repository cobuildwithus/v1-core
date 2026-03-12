# Routing Season Decay And Terminal Relist Guard

## Goal

Close the community-routing heartbeat loophole by moving lazy score decay to global season boundaries, make prune and add flows best-effort sync stale treasuries before lifecycle checks, and prevent terminal goals from being re-added through the community goal registry.

## Scope

- `src/hooks/CobuildSplitHook.sol`
- `src/tcr/CommunityGoalRegistry.sol`
- `test/hooks/CobuildSplitHook.t.sol`
- `test/tcr/CommunityGoalRegistry.t.sol`
- `ARCHITECTURE.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`

## Constraints

- Do not touch `lib/**`.
- Preserve ownerless registry and selectable-vs-listed separation.
- Keep historical backlog routing permissionless and paginated.
- Treat stale lifecycle progression as best-effort sync, not fail-open terminalization.
- Respect existing unrelated worktree edits.

## Acceptance Criteria

- Explicit-route routing scores decay by `currentSeason - lastUpdatedSeason`, where seasons are global `ROUTING_SCORE_HALF_LIFE` epochs.
- Same-season micro-routes do not buy a full extra half-life for historical routing weight.
- `pruneTerminalGoal(goalId)` attempts `goal.sync()` before deciding prunability and still remains permissionless.
- Terminal/prunable goals cannot be re-added through `CommunityGoalRegistry.addItem(...)`.
- Regression tests cover the season-boundary heartbeat case and the sync-aware prune/relist behavior.
- Required Solidity verification and completion workflow passes are green.

## Progress Log

- 2026-03-11: Read routing architecture/spec/process docs, current hook/registry code, and the focused hook/registry test suites.
- 2026-03-11: Replaced timestamp-based routing-score refresh with global season-index decay in `CobuildSplitHook` and added a same-season-heartbeat regression.
- 2026-03-11: Made `CommunityGoalRegistry` best-effort sync stale goals before prune/add lifecycle checks, blocked terminal relists, and added registry regressions for sync-aware prune and add validation.
- 2026-03-11: Focused hook coverage passed with `forge test --match-path test/hooks/CobuildSplitHook.t.sol`; a subsequent registry rerun was blocked by unrelated active `BudgetTCR` interface edits elsewhere in the shared worktree.
- 2026-03-11: Completion workflow results:
  - simplify subagent reported no behavior-preserving cleanup needed,
  - coverage audit and final review were completed locally after the follow-on subagent path did not return usable results in the shared-worktree state,
  - local final review found no new routing-specific correctness or security issues beyond the preexisting shared-worktree breakage.
- 2026-03-11: Required verification in the shared worktree failed because unrelated in-flight `BudgetTCR` / managed-goal changes elsewhere in the repo were uncompilable.
- 2026-03-11: Isolated verification on a temporary clean snapshot containing only this routing diff passed:
  - `forge test --match-path test/hooks/CobuildSplitHook.t.sol`
  - `forge test --match-path test/tcr/CommunityGoalRegistry.t.sol`
  - `FOUNDRY_PROFILE=default TEST_SCOPE_SKIP_SHARED_BUILD=1 pnpm -s test:lite:shared`
  - `pnpm -s lint:solidity:warnings`

## Open Risks

- Global-season decay changes the exact cliff location for lazy routing scores; tests must pin the intended boundary semantics.
- Sync-aware add/prune paths must stay best-effort so transient sync failures do not silently make live goals prunable.
Status: completed
Updated: 2026-03-11
Completed: 2026-03-11

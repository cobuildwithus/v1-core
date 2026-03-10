# Goal

Add a concrete community goal registry TCR as the canonical onchain source of selectable community goals, and rewire `CobuildSplitHook` to read that registry instead of maintaining its own curated goal list.

# Scope

- `src/tcr/CommunityGoalRegistry.sol`
- `src/tcr/interfaces/ICommunityGoalRegistry.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/interfaces/ICobuildSplitHook.sol`
- Focused tests in `test/hooks/` and `test/tcr/`
- Matching docs under `agent-docs/**` and `ARCHITECTURE.md`

# Constraints

- Keep the current routing model where only explicit wrapper-routed payments update observed volume.
- Preserve the current fixed init-time wrapper route setter and fail-closed historical routing behavior.
- The registry should be the canonical donor-visible/selectable goal source; the split hook should become a thin router over that source.
- System-goal pinning and pause/unpause backstop actions may exist on the registry, but the hook should not regain default-route/escrow/manual-curation surfaces.
- Do not touch `lib/**`.
- Avoid unrelated active goal-treasury / spend-policy worktree files.

# Acceptance criteria

- `CommunityGoalRegistry` extends `GeneralizedTCR` and supports goal listing/removal through standard TCR flow.
- Registry exposes the selectable goal view the split hook needs for explicit route validation and historical default derivation.
- `CobuildSplitHook` no longer stores its own approved-goal list or goal-treasury curation state.
- Explicit routes validate against the registry and raw direct/historical routing derive candidate goals from registry selectability.
- Focused tests cover registry listing/selectability behavior and split-hook routing against the registry-backed goal set.
- Matching docs describe the registry as the canonical community goal source.

# Progress log

- 2026-03-10: Reviewed the uploaded registry-TCR patch, current `GeneralizedTCR` extension points, and the current fixed-init community routing implementation. The uploaded split-hook patch is stale relative to the newer ownerless/defaultless routing model, so this task will integrate only the registry ideas into the current router shape.
- 2026-03-10: Added `CommunityGoalRegistry` and `ICommunityGoalRegistry`, extended listings to carry validated `goalTreasury` sinks, and rewired `CobuildSplitHook` / `ICobuildSplitHook` to validate and derive routing from registry state instead of local goal-manager curation.
- 2026-03-10: Updated focused coverage in `test/hooks/CobuildSplitHook.t.sol`, `test/tcr/CommunityGoalRegistry.t.sol`, and `test/juicebox/CobuildPaymentTerminal.t.sol` for registry-backed routing, canonical `goalId` item identity, system-goal backstop behavior, and hook init mismatch guards.
- 2026-03-10: Updated architecture/spec/reference docs so `CommunityGoalRegistry` is documented as the canonical donor-visible goal source and `CobuildSplitHook` is documented as a thin registry-backed router.
- 2026-03-10: Simplify pass extracted a shared hook goal-payment helper and shared registry listing setter, then preserved behavior with rerun focused suites.
- 2026-03-10: Final verification passed:
  - `forge test --match-path test/hooks/CobuildSplitHook.t.sol`
  - `forge test --match-path test/tcr/CommunityGoalRegistry.t.sol`
  - `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol`
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `bash scripts/check-agent-docs-drift.sh`
  - `bash scripts/doc-gardening.sh --fail-on-issues`

# Open risks

- Registry-selectability checks must remain fail-closed and should not silently admit malformed/self-referential goals.
- Replacing local goal metadata with registry reads changes several tests and may expose assumptions in current direct-pay beneficiary routing.

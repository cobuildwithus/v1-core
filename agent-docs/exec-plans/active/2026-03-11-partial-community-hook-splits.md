# Mixed Cobuild Reserved Splits

## Goal (incl. success criteria):
- Let a community revnet keep exactly one live Cobuild hook split while also allowing sibling reserved splits.
- Scope pending-route snapshots and consumption to the Cobuild hook's reserved-token slice so donor-selected routes only govern that slice.
- Keep the tree compiling and verified with updated tests and docs.

## Constraints/Assumptions:
- Upstream Nana/REV mixed reserved splits are the target behavior; `v1-core` should stop imposing a sole-full-bucket hook requirement.
- Existing in-flight routing-score rename/season-boundary edits in `CobuildSplitHook` and its tests must be preserved.
- Exactly one nonzero reserved split entry may point at the Cobuild hook for a live community ruleset.

## Key decisions:
- Reuse current pending-route state by storing the hook-slice backlog snapshot, not the project-wide pending reserved balance.
- Fail community registration if the live reserved split group has zero or multiple nonzero entries pointing at the Cobuild hook.
- Cancel pending routes when the new pay creates no hook callback amount after split rounding, even if other sibling reserved splits still receive tokens.

## State:
- Done.

## Done:
- Re-read Nana/REV upstream split semantics and confirmed mixed reserved splits are supported upstream.
- Mapped the local `CobuildCommunityTerminal` and `CobuildSplitHook` seams that still assume a full reserved bucket.
- Inspected current worktree overlap from the in-flight routing-score cutover.
- Patched the terminal/hook to use hook-slice backlog accounting and allow sibling reserved splits.
- Updated unit/factory/integration tests and architecture/spec docs for mixed-split semantics.
- Added pay-time regression tests covering post-registration split-group drift and mid-pay split-percent drift.
- Re-ran the focused Cobuild forge suites plus `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings` successfully after the coverage audit hardening.

## Now:
- None.

## Next:
- None.

## Open questions (UNCONFIRMED if needed):
- None.

## Working set (files/ids/commands):
- `src/juicebox/CobuildCommunityTerminal.sol`
- `src/hooks/CobuildSplitHook.sol`
- `test/juicebox/CobuildCommunityTerminal.t.sol`
- `test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
- `test/hooks/CobuildSplitHook.t.sol`
- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`

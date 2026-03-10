# Goal

Simplify community routing so the split hook has no owner/default-beneficiary/default-route/escrow surfaces, uses a fixed init-time goal manager to curate approved goals, and routes raw direct community pays to goal treasury beneficiaries derived from approved goal metadata.

# Scope

- `src/interfaces/ICobuildSplitHook.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/juicebox/CobuildPaymentTerminal.sol`
- Focused tests in `test/hooks/` and `test/juicebox/`
- Matching docs under `agent-docs/**` and `ARCHITECTURE.md`

# Constraints

- The wrapper address/route setter should be fixed at initialization.
- The only privileged mutable surface on the hook should be a fixed init-time goal manager that can add/remove approved goals.
- Raw direct community pays should route using historical explicit-volume weights only, with each child goal payment using that goal's treasury as beneficiary.
- Remove default beneficiary, manual default route, escrow, and sweep behavior entirely.
- Keep the goal TCR integration boundary lightweight; this pass can assume the goal manager curates approved goals directly.
- Do not touch `lib/**`.

# Acceptance criteria

- Explicit wrapper-routed payments still route immediately and record observed volume.
- Wrapper payments without explicit goal metadata use historical explicit-volume routing only and fail closed if no usable history exists.
- Raw direct community pays use historical explicit-volume routing only, with goal treasury addresses as downstream beneficiaries.
- The split hook no longer exposes owner/default/sweep APIs or retains unrouted balances on a privileged path.
- Approved-goal metadata includes or resolves the goal treasury needed for raw direct-pay routing.
- Focused tests cover direct-pay treasury beneficiaries, removed fallback behavior, and fixed-manager goal curation.

# Progress log

- 2026-03-10: Opened plan, claimed the task in `COORDINATION_LEDGER.md`, and started re-reading the current post-market-default routing implementation plus goal deployment topology.
- 2026-03-10: Replaced owner/default/escrow surfaces in `ICobuildSplitHook` and `CobuildSplitHook` with fixed init-time `routeSetter` + `goalManager`, approved-goal treasury metadata, historical-only direct-pay routing, and fail-closed no-history behavior.
- 2026-03-10: Rewrote focused hook tests around goal-treasury direct-pay beneficiaries and fixed-role curation, and updated the payment-terminal mock split-hook surface for the slimmer interface.
- 2026-03-10: Focused Forge coverage passed for `test/hooks/CobuildSplitHook.t.sol` and `test/juicebox/CobuildPaymentTerminal.t.sol` with the usual narrowed `--skip goals --skip invariant` scope.
- 2026-03-10: Updated architecture/spec/reliability/security/reference docs to remove default-beneficiary/manual-default/escrow language and document goal-treasury sink beneficiaries for raw direct pays.
- 2026-03-10: Applied a final hook simplify pass, added goal-treasury lookup-revert coverage in `test/hooks/CobuildSplitHook.t.sol`, and reran the focused hook suite to 16/16 passing.
- 2026-03-10: Final required gates passed on the post-coverage tree: `pnpm -s lint:solidity:warnings` and `pnpm -s verify:required`.

# Open risks

- `goalId -> goalTreasury` resolution needs to stay fail-closed and must not silently trust malformed approved-goal entries.
- Removing manual defaults and escrow means wrapper empty-metadata payments and raw direct pays will revert before any explicit signal exists.
Status: completed
Updated: 2026-03-10
Completed: 2026-03-10

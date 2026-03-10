Completion date: 2026-03-10
Resulting PR(s): none
Follow-up items: none

# Community Routing Hardening

## Goal

Tighten the community reserved-token routing path so the hook enforces its full-bucket routing assumption, shared proportional allocation math has one implementation, and downstream goal-terminal calls fail closed on invalid terminal surfaces or partial token outflow.

## Why

- `CobuildSplitHook.processSplitWith(...)` assumes its callback amount represents the full reserved-token bucket relevant to the wrapper snapshot/backlog math.
- Proportional allocation math is duplicated across multiple routing/accounting helpers.
- Goal-terminal lookup and pay calls currently trust any nonzero `primaryTerminalOf(...)` result and do not assert actual token outflow from the hook.

## Scope

- Add an explicit reserved-split runtime invariant in `CobuildSplitHook`.
- Centralize proportional allocation math behind one helper used by routing and observed-volume accounting.
- Harden goal-terminal validation in `CobuildSplitHook` and `CommunityGoalRegistry`.
- Add targeted regression coverage for the new invariant and terminal/outflow checks.

## Constraints

- No `lib/**` edits.
- Preserve wrapper backlog deferral semantics and explicit-volume-only historical signal updates.
- Keep hook/registry dependency boundaries explicit and fail closed on invalid terminal configuration.

## Acceptance criteria

- Fractional reserved-split callbacks revert instead of being silently treated as whole-bucket routing.
- Shared proportional allocation helper drives all current route/accounting call sites.
- Goal-terminal calls reject EOAs/non-contract terminals and revert if the hook does not actually spend the expected token amount.
- Regression tests cover the new runtime invariant and terminal hardening.

## Progress log

- 2026-03-10: Claimed hook/registry/test scope in `COORDINATION_LEDGER.md` and reviewed wrapper, hook, registry, and current routing tests against the reported issues.
- 2026-03-10: Implemented a full-bucket reserved-split runtime invariant in `CobuildSplitHook`, centralized proportional allocation math behind one helper, and hardened goal-terminal handling with contract-code validation plus exact hook-outflow postconditions.
- 2026-03-10: Hardened `CommunityGoalRegistry` terminal checks so no-code primary terminals are treated as not configured for selectability and system-goal pinning.
- 2026-03-10: Added targeted regressions for fractional split rejection, no-code terminals, exact-outflow mismatch, rollback atomicity on later-leg under-spend, gas-suite context alignment, and registry selectability/pinning on no-code terminals.
- 2026-03-10: Updated architecture/spec/reliability docs to state the full-bucket reserved-split invariant explicitly.
- 2026-03-10: Verification passed via `forge test --match-path test/hooks/CobuildSplitHook.t.sol`, `forge test --match-path test/hooks/CobuildSplitHookGas.t.sol`, `forge test --match-path test/tcr/CommunityGoalRegistry.t.sol`, `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol`, `pnpm -s verify:required`, and `pnpm -s lint:solidity:warnings`.
- 2026-03-10: Completion workflow passes completed: simplify pass suggested one dead historical-volume cleanup and one redundant terminal-address check cleanup, coverage audit added an atomic rollback regression in `test/hooks/CobuildSplitHook.t.sol`, and final completion audit reported no findings.

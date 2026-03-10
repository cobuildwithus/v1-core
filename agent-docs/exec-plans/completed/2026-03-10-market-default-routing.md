# Goal

Extend community revnet routing so non-explicit wrapper payments can route through a historical default derived from explicit routed volume only.

# Scope

- `src/interfaces/ICobuildSplitHook.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/juicebox/CobuildPaymentTerminal.sol`
- Focused unit coverage under `test/hooks/` and `test/juicebox/`
- Matching `agent-docs/**` updates for architecture/spec/security/reference changes

# Constraints

- Count only explicit routed volume toward the market default; defaulted/direct fallback flows must not reinforce the historical signal.
- Preserve beneficiary propagation through the wrapper for both explicit routes and historical-default wrapper routes.
- Raw direct community pays still lack pay-beneficiary context in split-hook callbacks and therefore can only auto-route when a configured default beneficiary is available.
- Keep community deployer/factory integration out of scope.
- Do not touch `lib/**`.

# Acceptance criteria

- Explicit routed wrapper payments still route immediately and now record observed per-goal volume.
- Wrapper payments without explicit goal metadata seed a one-shot historical-default route and still route in one transaction.
- Split-hook fallback behavior prefers a derived historical route from explicit volume, ignoring unapproved goals, before falling back to manual default route or escrow.
- Direct community pays can use the historical default only when a default beneficiary is configured.
- Focused regression tests cover explicit-volume accounting, default derivation, beneficiary propagation, and non-reinforcing fallback behavior.

# Progress log

- 2026-03-10: Opened plan, claimed the task in `COORDINATION_LEDGER.md`, and reviewed the prototype notes plus current split-hook/wrapper implementation.
- 2026-03-10: Extended `ICobuildSplitHook`, `CobuildSplitHook`, and `CobuildPaymentTerminal` so explicit routed pays record historical volume, empty-metadata wrapper pays seed one-shot historical-default routing, and direct fallback routing uses historical explicit-volume shares only for `defaultBeneficiary`.
- 2026-03-10: Expanded focused tests to cover explicit-volume accounting, historical-default routing, manual default fallback without history, ignored unapproved goals, and wrapper pending-route behavior for both explicit and empty-metadata pays.
- 2026-03-10: Focused Forge coverage passed with narrowed build scope due unrelated repo test breakage outside this change set:
  - `forge test --match-path test/hooks/CobuildSplitHook.t.sol --skip goals --skip invariant`
  - `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol --skip goals --skip invariant`
- 2026-03-10: Updated architecture/spec/security/reliability/reference docs for the historical market-default routing behavior.
- 2026-03-10: Simplify pass removed redundant historical-route storage clearing and dead array copies in `CobuildSplitHook`, then reran focused hook coverage after fixing the copy/clear ordering.
- 2026-03-10: Coverage/final-review follow-ups added direct-pay escrow regressions without `defaultBeneficiary`, precedence tests proving historical routing wins over manual defaults, a `historicalRoute()` terminal-filter regression, and a wrapper regression for zero-beneficiary-token historical pays that clear stale pending routes instead of reverting.
- 2026-03-10: Required verification reran green via `pnpm -s verify:required`; warning-baseline and doc checks are part of final close-out for this task.
- 2026-03-10: Final close-out checks passed via `pnpm -s lint:solidity:warnings`, `bash scripts/doc-gardening.sh --fail-on-issues`, and `bash scripts/check-agent-docs-drift.sh`.

# Open risks

- Historical-route derivation introduces new persistent accounting and route-selection state that must stay fail-closed around approval changes and zero-volume cases.
- The wrapper still treats `metadata` as routing metadata only; root-pay metadata passthrough remains out of scope unless required by product wiring.
- The default Forge lane still has unrelated pre-existing compilation failures in other test files, so targeted verification currently requires narrowed `--skip goals --skip invariant` coverage for these touched suites.
Status: completed
Updated: 2026-03-10
Completed: 2026-03-10

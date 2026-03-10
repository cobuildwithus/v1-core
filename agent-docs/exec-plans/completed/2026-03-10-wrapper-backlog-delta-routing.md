Completion date: 2026-03-10
Resulting PR(s): none
Follow-up items: monitor the submitted `review:gpt` audit; broad repo `verify:required`/`lint:solidity:warnings` are currently blocked by the active `Codex-main-6` untracked test file `test/ERC20VotesArbitratorStakeVaultSlashing.t.sol`, so this task closed with narrowed focused Forge verification for the touched suites plus the latest passing queue-backed `verify:required` run before that foreign file entered the shared gate.

# Wrapper Backlog Delta Routing

## Goal

Keep wrapper-driven community mints on the happy path even when unrelated reserved-token backlog already exists, by routing only the current payer's newly created reserved-token delta through their selected route and deferring older backlog to a separate permissionless historical flush path.

## Why

- The controller exposes only one aggregate `pendingReservedTokenBalanceOf(projectId)` bucket and one flush-all entrypoint.
- A wrapper-seeded pending route cannot safely consume old backlog without allowing a new payer route to capture tokens created by earlier direct community pays.
- Reverting wrapper mints on pre-existing backlog is fail-closed but undesirable for payer UX.

## Scope

- Add a backlog snapshot to wrapper-seeded pending routes.
- Update `CobuildPaymentTerminal` to snapshot controller backlog before the pay and always flush only after the pay creates new reserved tokens.
- Update `CobuildSplitHook` to:
  - route only the new reserved-token delta through the pending explicit/historical route,
  - escrow older backlog into hook-managed storage,
  - expose a permissionless backlog flush path that routes backlog via historical explicit-route weights to goal treasuries on a best-effort basis.
- Add unit + integration coverage for mixed backlog/new-delta behavior and backlog flush behavior.
- Update product-facing protocol docs and review-gpt packaging inputs for the changed semantics.

## Constraints

- No `lib/**` edits.
- Preserve explicit-route observed-volume semantics: only the current payer's explicit delta should reinforce history.
- Backlog handling must not re-route old controller backlog through the current payer's beneficiary/goal choice.
- Backlog flush should not block wrapper mints.

## Acceptance criteria

- Wrapper pays with explicit goal routing succeed even when unrelated controller reserved-token backlog already exists.
- Only the current pay's newly created reserved-token delta routes through the payer-selected goals and updates historical observed volume.
- Older backlog is preserved for a separate permissionless historical flush and never captured by the current payer's route.
- Direct community pays and historical-default paths defer backlog instead of reverting when no historical route is available.
- Focused unit/integration tests and doc updates cover the new backlog snapshot + deferred flush behavior.

## Progress log

- 2026-03-10: Claimed scope in `COORDINATION_LEDGER.md`, opened this plan, and reviewed the wrapper/controller/split-hook flow plus the product constraint around never failing payer-selected routes on unrelated backlog.
- 2026-03-10: Implemented backlog snapshot routing in `CobuildPaymentTerminal` and hook-managed historical backlog deferral/flush behavior in `CobuildSplitHook`, including interface updates and best-effort historical backlog handling.
- 2026-03-10: Expanded wrapper, hook, gas, and core integration coverage for mixed backlog/new-delta behavior; later added an end-to-end lifecycle integration test for `no history -> backlog parked -> explicit route seeds history -> permissionless flush`.
- 2026-03-10: Updated architecture/spec/reliability/reference docs for the new deferred-backlog semantics.
- 2026-03-10: Completion workflow passes completed: simplify pass found only behavior-preserving cleanup, coverage audit reported no mandatory test additions, and final completion audit reported no findings.
- 2026-03-10: Local queue-backed `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings` passed before a separate active task introduced the untracked `test/ERC20VotesArbitratorStakeVaultSlashing.t.sol`; after that shared-worktree compile blocker appeared, focused Forge verification for the touched suites passed with `--skip test/ERC20VotesArbitratorStakeVaultSlashing.t.sol --skip goals --skip invariant`, and `review:gpt` was submitted with an expanded audit ZIP that included `lib/nana-core-v5/src/**/*.sol` except `periphery/JBMatchingPriceFeed.sol`.

## Open risks

- State-machine complexity between controller pending balance, hook pending route, and hook-managed backlog.
- Historical backlog distribution may be O(selectable goals); keep payer path separate from permissionless backlog flush.
- Need to avoid partial-accounting bugs when direct community pays coexist with wrapper mints.

## Verification

- `forge test --match-path test/hooks/CobuildSplitHook.t.sol --skip test/ERC20VotesArbitratorStakeVaultSlashing.t.sol --skip goals --skip invariant -vv`
- `forge test --match-path test/hooks/CobuildSplitHookGas.t.sol --skip test/ERC20VotesArbitratorStakeVaultSlashing.t.sol --skip goals --skip invariant -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol --skip test/ERC20VotesArbitratorStakeVaultSlashing.t.sol --skip goals --skip invariant -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol --skip test/ERC20VotesArbitratorStakeVaultSlashing.t.sol --skip goals --skip invariant -vv`
- `pnpm -s verify:required` (latest rerun blocked by active foreign untracked test file; earlier queue-backed run passed before that compile blocker entered the shared worktree)
- `pnpm -s lint:solidity:warnings` (latest rerun blocked by the same foreign untracked test file; earlier run passed before that compile blocker entered the shared worktree)
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
- `review:gpt` audit with audit ZIP that explicitly includes relevant Juicebox/nana-core files

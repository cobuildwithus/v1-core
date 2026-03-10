Completion date: 2026-03-10
Resulting PR(s): none
Follow-up items: if wrapper historical-default routing is expected to scale to the same goal counts as backlog flushes, it still needs its own pagination/deferred-routing design; this change only paginates permissionless hook-managed backlog flushes.

# Split Hook Historical Pagination

## Goal

Remove the effective gas cap on historical backlog routing by making `CobuildSplitHook` historical backlog distribution resumable in chunks, while preserving the current backlog-delta invariant: a fresh payer-selected route must only apply to that payer's newly created reserved-token delta and must never capture older backlog.

## Why

- `flushHistoricalBacklog()` currently routes all selectable historically weighted goals in one transaction.
- The gas-profile test shows historical routing crosses a practical 16M gas threshold at roughly ~100 active goals.
- Historical backlog is liveness-oriented and permissionless, so it should be chunkable and resumable instead of forcing a whole-route scan in one call.

## Scope

- Add a paginated historical backlog flush path to `CobuildSplitHook`.
- Expose the necessary views/state so callers can inspect backlog-flush progress.
- Preserve observed-volume semantics: explicit payer-selected routes still reinforce history, historical routing still does not.
- Add focused unit, integration, and gas-profile coverage for chunked backlog routing and resume behavior.
- Update protocol docs to describe the paginated historical backlog model and any remaining non-paginated historical paths.

## Constraints

- No `lib/**` edits.
- Do not route older backlog through a current payer-selected route.
- Keep the tree compiling through each change set.
- Prefer simplification over backward-compat scaffolding; there are still no live deployments.

## Acceptance criteria

- Hook-managed historical backlog flushes are resumable in bounded chunks instead of requiring one full-route transaction.
- Chunked backlog routing preserves exact total accounting and does not route older backlog through a current payer-selected route.
- New deferred backlog or newly recorded explicit history resets active backlog-flush progress so remaining backlog can use current weights.
- Direct historical callbacks no longer piggyback older parked backlog through an unrelated payer transaction.
- Focused unit, gas-profile, and integration coverage plus required Solidity gates are green.

## Progress log

- 2026-03-10: Claimed scope in `COORDINATION_LEDGER.md`, opened this plan, and reviewed the hook/controller/test paths to isolate the historical backlog gas bottleneck from the payer-scoped backlog-delta invariants.
- 2026-03-10: Implemented paginated `flushHistoricalBacklog(maxGoalCount)` with epoch-based processed-goal tracking, a backlog-progress view, and reset-on-new-backlog/new-history behavior.
- 2026-03-10: Changed direct historical callbacks to defer new amounts when older hook-managed backlog is already parked, so unrelated direct calls no longer piggyback old backlog flush work.
- 2026-03-10: Expanded hook unit coverage for chunk progress, zero page-size rejection, reset-on-new-backlog, reset-on-new-explicit-history, and direct-pay deferral while backlog exists.
- 2026-03-10: Added an integration regression proving paginated permissionless backlog flush can resume across pages on the real wrapper/controller path, and a gas-profile regression showing a 16-goal chunk stays below 16M gas at 512 total historical goals.
- 2026-03-10: Simplify pass found no additional behavior-preserving production cleanup worth applying; coverage audit found one real gap and added the explicit-history-reset regression; final completion review found no correctness/security findings.
- 2026-03-10: Verification passed with `forge test --match-path test/hooks/CobuildSplitHook.t.sol -vv`, `forge test --match-path test/hooks/CobuildSplitHookGas.t.sol -vv`, `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol -vv`, `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol -vv`, `pnpm -s verify:required`, and `pnpm -s lint:solidity:warnings`.

## Open risks

- Pending historical-default routing to a beneficiary still uses the one-shot historical route scan; this task did not paginate or defer that path.
- Historical backlog pagination deliberately re-evaluates remaining backlog against current selectable goals/observed history after resets; that is the intended liveness tradeoff, but it is not a frozen snapshot model.

## Verification

- `forge test --match-path test/hooks/CobuildSplitHook.t.sol -vv`
- `forge test --match-path test/hooks/CobuildSplitHookGas.t.sol -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol -vv`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

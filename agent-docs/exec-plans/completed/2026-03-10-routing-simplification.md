Completion date: 2026-03-10
Resulting PR(s): none
Follow-up items: none.

# Routing Simplification

## Goal

Simplify community reserved-token routing by making the wrapper explicit-route only and moving all non-explicit historical routing onto the single paginated hook-managed backlog flush path.

## Why

- The current code still carries multiple historical-routing modes: wrapper historical-default routing, direct historical routing, and paginated backlog routing.
- Only the paginated backlog path scales cleanly under larger goal counts.
- Removing the extra same-transaction historical modes materially reduces state-machine complexity.

## Scope

- Remove wrapper historical-default pending-route mode from `CobuildPaymentTerminal`.
- Remove `beginPendingHistoricalRoute`, `usesHistoricalDefault`, and beneficiary-based historical routing from `CobuildSplitHook`.
- Make no-pending-route controller callbacks always defer reserved tokens into hook-managed backlog.
- Keep explicit wrapper-selected routing and paginated `flushHistoricalBacklog(maxGoalCount)`.
- Rewrite affected tests/docs to match the simplified behavior, including the top-level `ARCHITECTURE.md` routing summary.

## Constraints

- No `lib/**` edits.
- Preserve the backlog-delta invariant for explicit wrapper routes.
- Keep paginated backlog flushing permissionless and historically weighted to goal treasuries.
- Shared worktree contains unrelated dirty files; do not touch them.

## Acceptance criteria

- Wrapper-selected explicit routes remain same-transaction, payer-scoped, and backlog-delta safe.
- Empty-metadata wrapper pays no longer create beneficiary-preserving historical pending routes; they defer reserved tokens into hook-managed backlog.
- Controller callbacks without a pending explicit route always defer to hook-managed backlog.
- Historical treasury routing remains permissionless and paginated through `flushHistoricalBacklog(maxGoalCount)`.
- Scoped tests and routing docs reflect the simplified single historical-routing engine.

## Progress log

- 2026-03-10: Claimed the task in `COORDINATION_LEDGER.md` and opened this execution plan before changing production files.
- 2026-03-10: Removed wrapper historical-default routing from `CobuildPaymentTerminal` and removed the corresponding pending-route mode from `CobuildSplitHook`.
- 2026-03-10: Simplified `CobuildSplitHook.processSplitWith(...)` so explicit pending routes remain the only same-transaction routing path and all no-pending-route controller callbacks defer into backlog.
- 2026-03-10: Reworked wrapper, hook, gas, and integration coverage to lock in the new explicit-only wrapper behavior plus paginated backlog-only historical routing.
- 2026-03-10: Updated durable routing docs, then fixed remaining top-level `ARCHITECTURE.md` drift after the completion audit flagged it.
- 2026-03-10: Completion workflow results:
  - simplify: no material behavior-preserving cleanup worth taking,
  - test-coverage-audit: no high-impact missing deterministic test found; only lower-priority recommendations remained,
  - task-finish-review: no findings; only residual note was doc drift in `ARCHITECTURE.md`, which was fixed before close-out.

## Open risks

- This is an intentional product behavior change: empty-metadata wrapper pays no longer preserve payer beneficiary on same-transaction historical routing.
- Historical backlog distribution still depends on someone calling the permissionless paginated flush path.
- Backlog flush behavior remains historically weighted to goal treasuries only; there is no beneficiary-preserving default route anymore.

## Verification

- `forge test --match-path test/hooks/CobuildSplitHook.t.sol -vv`
- `forge test --match-path test/hooks/CobuildSplitHookGas.t.sol -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol -vv`
- `pnpm -s verify:required` (passed)
- `pnpm -s lint:solidity:warnings` (passed)
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

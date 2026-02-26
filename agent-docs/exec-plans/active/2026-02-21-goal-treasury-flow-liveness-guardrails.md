# Goal Treasury Flow-Rate Liveness Guardrails

## Objective
- Prevent `GoalTreasury` activation/sync from bricking when direct `setFlowRate(target)` reverts due runtime solvency/buffer constraints.
- Preserve existing goal spend-down target semantics while adding bounded fallback behavior.

## Scope
- `src/goals/library/TreasuryFlowRateSync.sol`
- `src/goals/GoalTreasury.sol`
- `test/goals/helpers/TreasurySharedMocks.sol`
- `test/goals/GoalTreasury.t.sol`
- `ARCHITECTURE.md`
- `agent-docs/references/goal-funding-and-reward-map.md`

## Plan
1. Add resilient flow-rate apply helper: try target, then retry with max-safe-capped fallback, then zero-rate fallback.
2. Switch `GoalTreasury._syncFlowRate` to resilient helper and keep emitted target/applied reporting.
3. Add characterization tests for:
   - target revert + max-safe fallback success,
   - target/max-safe revert + zero fallback success,
   - persistent write failure still reverts.
4. Update architecture/reference docs to capture new fallback policy.
5. Run `forge build -q` and `pnpm -s test:lite`.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

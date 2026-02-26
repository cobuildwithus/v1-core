# Child Sync Insufficient-Balance Deferral

Status: complete
Created: 2026-02-24
Updated: 2026-02-24

## Goal

Prevent parent operations from reverting when parent-synced child flow increases are temporarily unaffordable.

## Scope

- In scope:
  - `src/library/FlowRates.sol` child-sync affordability path.
  - `test/flows/FlowChildSyncBehavior.t.sol` coverage for deferred behavior and parent liveness.
- Out of scope:
  - Any `lib/**` change.
  - Broader flow-rate math redesign.
  - Unrelated TCR/treasury changes.

## Constraints

- Preserve existing behavior for non-insufficient-balance paths.
- Keep deferred children queued for later retries.
- Required Solidity verification: `pnpm -s verify:required`.

## Acceptance Criteria

1. Child sync no longer reverts parent tx on insufficient affordability.
2. Child remains queued when insufficient affordability occurs.
3. Affordability uses Superfluid realtime available balance semantics.
4. Tests assert non-bricking parent update behavior.

## Progress

- Implemented child-sync insufficiency handling in `FlowRates._attemptChildIncrease`:
  - switched affordability source from `balanceOf` to `realtimeBalanceOfNow` available balance,
  - replaced hard revert with defer behavior that re-queues child and restores snapshot.
- Updated child-sync behavior tests to assert:
  - insufficient balance defers/requeues instead of reverting,
  - deferred child can retry successfully after funding,
  - parent `setTargetOutflowRate` remains live while deferred child stays queued,
  - mixed child-sync batches continue processing other queued children when one child is deferred.
- Verification executed:
  - `forge test --skip GeneralizedTCRChallengeRequest.t.sol --skip GeneralizedTCREvidenceTimeout.t.sol --match-path test/flows/FlowChildSyncBehavior.t.sol --match-test "test_setChildFlowRate_insufficientBalance_defersAndRequeues|test_setChildFlowRate_insufficientBalance_defersThenRetriesWhenAffordable|test_setTargetOutflowRate_childSyncInsufficientBalance_doesNotBrickParentUpdate|test_syncChildFlows_oneDeferredChild_doesNotBlockOtherQueuedChild"` (pass)
  - `forge test --skip GeneralizedTCRChallengeRequest.t.sol --skip GeneralizedTCREvidenceTimeout.t.sol --match-path test/flows/FlowChildSyncBehavior.t.sol` (pass)
  - `pnpm -s verify:required` (queue run passed; see `.git/agent-runtime/verify-queue-logs/verify-queue-20260224T190501Z-pid69356.log`)

# Debt-Lock Slash Weight Sync Mitigation

Status: active
Created: 2026-03-03
Updated: 2026-03-03

## Goal

Prove and mitigate the high-severity interaction where account-level child-sync debt can block
`syncAllocationForAccount` weight-only commits, allowing slashed underwriters to retain stale
goal-flow/budget-ledger weight until debt is repaired.

## Scope

- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `test/flows/FlowLedgerChildSyncProperties.t.sol`

## Constraints

- Preserve debt fail-close semantics for true recipient reallocation while debt exists.
- Do not modify `lib/**`.
- Keep behavior deterministic and externally observable through existing events/errors.
- Required verification before handoff:
  - `pnpm -s verify:required`

## Acceptance Criteria

- A regression test demonstrates that debt-locked weight-only sync path is currently blocked.
- Mitigation allows weight-only `syncAllocationForAccount` to proceed under debt.
- Recipient set/allocation changes remain blocked while debt exists.
- Existing debt lifecycle (`open/clear/repair`) remains intact.

## Design Notes

- Determine reallocation-vs-weight-only using previous/new recipient ids + allocations arrays.
- Apply debt gate only when allocation composition changed.
- Keep checkpoint/premium/child-sync execution unchanged for weight-only sync so ledger and
  coverage state can catch up after slash.

## Verification

- Targeted regression run:
  - `forge test --match-path test/flows/FlowLedgerChildSyncProperties.t.sol --match-test test_syncAllocationForAccount_weightOnlyCommit`
- Required gate:
  - `pnpm -s verify:required`

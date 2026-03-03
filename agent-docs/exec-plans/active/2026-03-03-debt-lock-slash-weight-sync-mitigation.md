# Debt-Lock Slash Weight Sync Mitigation

Status: active
Created: 2026-03-03
Updated: 2026-03-03

## Goal

Prove and mitigate the high-severity interaction where account-level child-sync debt can block
`syncAllocationForAccount` weight-only commits, allowing slashed underwriters to retain stale
goal-flow/budget-ledger weight until debt is repaired.

## Scope

- `src/interfaces/IAllocationPipeline.sol`
- `src/library/CustomFlowAllocationEngine.sol`
- `src/flows/CustomFlow.sol`
- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `test/flows/FlowLedgerChildSyncProperties.t.sol`

## Constraints

- Preserve debt fail-close semantics for true recipient reallocation while debt exists.
- Do not modify `lib/**`.
- Keep behavior deterministic and externally observable through existing events/errors.
- Required verification before handoff:
  - `pnpm -s verify:required`

## Acceptance Criteria

- Weight-only `syncAllocationForAccount` continues to proceed under existing debt.
- Weight-only maintenance sync does not open new debt on child-sync failure.
- Weight-only maintenance sync does not open new debt on gas-budget skip.
- Recipient composition/allocation edits remain debt-gated and debt-open semantics are unchanged.
- Existing debt lifecycle (`open/clear/repair`) remains intact.

## Design Notes

- Thread explicit commit context (`AllocationEdit` vs `MaintenanceSync`) from `CustomFlow` into
  allocation pipeline execution.
- Keep debt gate only for composition-changing commits.
- Use debt write mode in pipeline (`OpenAndClear` for edits, `ClearOnly` for maintenance sync),
  with flattened early-continue control flow in debt policy.
- Keep checkpoint/premium/child-sync execution unchanged for maintenance sync so ledger and
  coverage state catch up without opening griefable debt.

## Verification

- Targeted regression run:
  - `forge test --match-path test/flows/FlowLedgerChildSyncProperties.t.sol --match-test test_syncAllocationForAccount_weightOnlyCommit`
- Required gate:
  - `pnpm -s verify:required`

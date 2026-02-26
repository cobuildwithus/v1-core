# 2026-02-21 Post-Change Cleanup Pass

## Goal
Simplify and de-duplicate recently changed goal-ledger-mode code paths (Proposals 1/2/4) without changing behavior.

## Scope
- `src/library/GoalFlowLedgerMode.sol`
- `src/flows/CustomFlow.sol`

## Constraints
- No behavior changes.
- Preserve existing revert selectors and fail-closed semantics.
- Keep API/ABI compatibility.

## Plan
1. Collapse duplicated ledger validation logic into shared internal helper.
2. Remove redundant stale-commit checks in wrapper sync paths.
3. Inline one-use helper in allocation path and keep naming consistent (`allocationScaled`).
4. Verify with required build + tests.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

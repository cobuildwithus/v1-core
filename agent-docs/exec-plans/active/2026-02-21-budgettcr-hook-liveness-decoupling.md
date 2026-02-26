# BudgetTCR Hook Liveness Decoupling

## Objective
- Prevent `GeneralizedTCR` request/dispute execution from reverting when BudgetTCR registration/removal side effects fail.
- Preserve permissionless progress via explicit retry entrypoints for deferred work.
- Keep changes localized to `BudgetTCR` without modifying base `GeneralizedTCR` hook ordering.

## Scope
- `src/tcr/BudgetTCR.sol`
- `src/tcr/interfaces/IBudgetTCR.sol`
- `src/tcr/storage/BudgetTCRStorageV1.sol`
- `test/BudgetTCR.t.sol`
- `test/BudgetTCRFlowRemovalLiveness.t.sol`
- `agent-docs/references/tcr-and-arbitration-map.md`

## Plan
1. Add minimal pending state for registration/removal side effects.
2. Make `_onItemRegistered` fail-open for TCR finality and queue failed activation.
3. Add permissionless activation retry path for registered-but-not-activated budgets.
4. Make `_onItemRemoved` fail-open for TCR finality and queue failed removal finalization.
5. Add permissionless removal-finalization retry path; keep existing retry method as compatibility alias.
6. Update tests to assert pending-state transitions and permissionless retries.
7. Run required verification commands.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

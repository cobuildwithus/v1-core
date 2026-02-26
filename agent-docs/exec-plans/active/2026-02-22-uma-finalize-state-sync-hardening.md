# UMA Resolver Finalize State-Sync Hardening

## Goal
Prevent resolver bookkeeping from silently desynchronizing from treasury pending-assertion state during UMA assertion finalization.

## Scope
- Update `src/goals/UMATreasurySuccessResolver.sol` finalize flow to gate behavior on treasury `pendingSuccessAssertionId()`.
- Keep the disabled/removed-budget escape path where treasury pending assertion is already cleared.
- Add explicit custom errors for pending-id mismatch and treasury apply/clear failures.
- Add regression coverage in `test/goals/UMATreasurySuccessResolver.t.sol` for mismatch, failure, and pre-cleared pending paths.
- Add post-assert allowance reset hygiene in `assertSuccess`.

## Invariants to Preserve
- Resolver must not mark an assertion finalized while treasury still tracks a different pending assertion id.
- If treasury still tracks the same assertion id, finalize must apply truthful result or clear false result; failures must revert.
- If treasury no longer tracks a pending assertion id, resolver can still finalize bookkeeping without applying success.

## Validation
- `forge build -q`
- `pnpm -s test:lite`

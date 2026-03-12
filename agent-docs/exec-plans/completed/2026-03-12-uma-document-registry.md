# 2026-03-12 UMA Success-Assertion Document Registry

Status: completed
Created: 2026-03-12
Completed: 2026-03-12

## Goal

- Add an onchain, hash-keyed text registry for success specs, assertion policies, and per-assertion evidence.
- Keep treasuries and listings hash-based while giving humans a canonical retrieval path for the exact hashed text.
- Make UMA assertions reference evidence by canonical hash instead of relying on free-form inline prose.

## Shipped

- Added `SuccessAssertionDocumentRegistry`, a write-once/idempotent `bytes32 => string` registry that validates `keccak256(bytes(text))`.
- Added `ISuccessAssertionDocumentRegistry` so resolver code depends on the minimal registry interface.
- Updated `UMATreasurySuccessResolver` to:
  - require registered spec/policy documents before `assertSuccess(...)`,
  - auto-register non-empty evidence text under `keccak256(bytes(evidence))`,
  - store `evidenceHashOfAssertion`,
  - emit `SuccessAssertionRequested` with the registry address plus canonical `specHash` / `policyHash` / `evidenceHash`,
  - include the registry address plus canonical hashes in the UMA claim text.
- Added focused registry tests and extended resolver tests for:
  - missing spec/policy documents,
  - empty evidence,
  - reusing pre-registered evidence,
  - structured event decoding for the registry address and canonical hashes.
- Updated UMA lifecycle/deployment docs to reflect the required registry registration flow.

## Verification

- `forge test test/goals/SuccessAssertionDocumentRegistry.t.sol` ✅
- `forge test test/goals/UMATreasurySuccessResolver.t.sol` ✅
- `pnpm -s verify:required` ✅
- `pnpm -s lint:solidity:warnings` ✅
- `pnpm -s build:sizes` ✅
- completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review` ✅

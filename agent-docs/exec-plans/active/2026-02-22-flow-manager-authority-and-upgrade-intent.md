# Flow Manager Authority and Upgrade Intent Hardening

Status: active
Created: 2026-02-22
Updated: 2026-02-22

## Goal

Address three flow-surface concerns:
- prevent allocation freezes from hook/ledger misconfiguration assumptions,
- remove leftover owner terminology where manager is the actual authority,
- make Flow/CustomFlow non-upgradeability intent explicit despite ERC1967 deployment wrappers.

## Scope

- In scope:
  - Flow-facing naming cleanup in `src/interfaces/IFlow.sol`, `src/Flow.sol`, and flow init helper/library paths.
  - Tests under `test/flows/**` that reference renamed flow access-control errors/params.
  - Explicit architecture docs updates for flow non-upgradeability intent.
  - Add regression coverage for "hook configured while ledger is unset" allocation behavior.
- Out of scope:
  - Changes under `lib/**`.
  - Reintroducing a separate owner role for flows.
  - Replacing ERC1967 child-flow deployment with clones in this patch.

## Constraints

- Keep manager/parent access behavior unchanged.
- Preserve existing ledger-mode safety checks (non-zero ledger still requires hook).
- Keep Flow runtime non-upgradeable.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress Log

- 2026-02-22: Created execution plan and began flow/auth terminology + hook-safety pass.
- 2026-02-22: Removed legacy flow `owner` authority naming in flow interfaces/modifiers/errors and aligned init config to manager-only semantics.
- 2026-02-22: Added explicit non-upgradeable flow runtime entrypoint (`upgradeToAndCall` -> `NON_UPGRADEABLE`) and updated upgrade-intent docs.
- 2026-02-22: Added regression test ensuring allocation succeeds when `GoalFlowAllocationLedgerHook` is set while `allocationLedger` is unset.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (fails in pre-existing dirty `BudgetTCR` paths; 810 passed / 11 failed)
  - failing suites: `test/BudgetTCR.t.sol`, `test/BudgetTCRFlowRemovalLiveness.t.sol`
  - observed root cause in dirty local `src/tcr/BudgetTCR.sol`: selector assembly writes `mstore(ptr, selector)` (zero selector in calldata position), unrelated to this flow patch

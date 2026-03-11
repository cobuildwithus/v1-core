# 2026-03-10 Explicit Flow Allocation APIs

## Goal

Remove sender-sensitive public/view allocation and preview APIs by making flow context explicit in runtime interfaces and by moving canonical external read helpers onto `CustomFlow`.

## Scope

- Runtime interface migration for allocation strategies and allocation pipeline preview.
- `CustomFlow` read wrappers for explicit, flow-owned allocation inspection.
- Budget-flow router explicit-flow query cleanup and status naming cleanup.
- Test and harness updates required to keep the tree compiling and behavior-covered.

## Constraints / Guardrails

- Preserve runtime allocation semantics and `onAllocationCommitted` caller-auth model.
- Do not overwrite unrelated in-flight edits already present in `src/hooks/GoalFlowAllocationLedgerPipeline.sol`.
- Avoid storage changes unless strictly required.
- Treat this as a breaking ABI change; update all affected call sites in one change set.

## Planned Files

- `src/interfaces/IAllocationStrategy.sol`
- `src/interfaces/IAllocationPipeline.sol`
- `src/interfaces/IBudgetFlowRouterStrategy.sol`
- `src/interfaces/IFlow.sol`
- `src/interfaces/IStakeVault.sol`
- `src/interfaces/IGoalLedgerStrategy.sol`
- `src/flows/CustomFlow.sol`
- `src/library/CustomFlowAllocationEngine.sol`
- `src/library/CustomFlowPreview.sol`
- `src/allocation-strategies/BudgetFlowRouterStrategy.sol`
- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `src/goals/StakeVault.sol`
- `src/teamflow/TeamFlow.sol`
- `agent-docs/references/flow-allocation-and-child-sync-map.md`
- `agent-docs/references/module-boundary-map.md`
- targeted tests / mocks / harnesses under `test/**`

## Symbol Plan

- Change `IAllocationStrategy.currentWeight` to `currentWeight(address flow, uint256 key)`.
- Change `IAllocationStrategy.canAllocate` to `canAllocate(address flow, uint256 key, address caller)`.
- Delete base-interface `canAccountAllocate` and `accountAllocationWeight`.
- Add explicit-flow account query methods on `IBudgetFlowRouterStrategy`.
- Add `CustomFlow` allocation read helpers for canonical external reads.
- Change pipeline preview to accept explicit `flow`.
- Rename ambiguous internal `closed` status plumbing in `BudgetFlowRouterStrategy`.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

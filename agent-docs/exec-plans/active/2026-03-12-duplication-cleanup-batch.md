# 2026-03-12 Duplication Cleanup Batch

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Reduce high-drift duplication across treasury assertion lifecycle, controller sync/prune loops, factory routing, and single-allocator strategies.
- Preserve current lifecycle, gating, and deployment semantics while shrinking duplicated control flow and policy recomputation.
- Finish with the required Solidity verification and completion-workflow passes.

## Scope

- In scope:
  - `src/goals/BudgetTreasury.sol`
  - `src/goals/GoalTreasury.sol`
  - `src/goals/library/TreasurySuccessAssertionLifecycle.sol`
  - `src/tcr/BudgetTCR.sol`
  - `src/goals/ManagedBudgetController.sol`
  - `src/goals/GoalFactory.sol`
  - `src/goals/library/GoalFactoryBudgetTcrRouting.sol`
  - `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`
  - `src/tcr/BudgetTCRFactory.sol`
  - `src/tcr/library/BudgetTCRInitValidation.sol`
  - `src/allocation-strategies/SingleAllocatorStrategy.sol`
  - `src/allocation-strategies/BudgetSingleAllocatorStrategy.sol`
  - `src/goals/library/GoalFactoryManagedPresetDeploy.sol`
  - `src/library/FlowSets.sol` if bytecode and scope headroom permit
  - targeted regression tests for touched lifecycle/deployment/strategy seams
- Out of scope:
  - changing treasury lifecycle semantics
  - changing premium/slash economics
  - changing managed/open preset product behavior
  - unrelated dirty worktree cleanup

## Constraints

- Respect the existing dirty worktree and do not overwrite unrelated edits.
- Keep controller-owned prune semantics explicit and preserve best-effort sync/finalization behavior.
- Treat treasury lifecycle, funds routing, and gate-policy wiring as security-sensitive.
- Child workers may inspect and patch only their assigned scope and must not run repo-wide verification.
- Any `FlowSets` cleanup is optional and must be skipped if it adds bytecode pressure or expands scope beyond low risk.

## Workstreams

1. Shared treasury assertion lifecycle helper extraction for `GoalTreasury` and `BudgetTreasury`.
2. Shared sync/prune loop helper for `BudgetTCR` and `ManagedBudgetController`.
3. Canonical no-premium / no-slash / no-gate routing resolver across factory and init validation.
4. Shared base for `SingleAllocatorStrategy` and `BudgetSingleAllocatorStrategy`.
5. Managed preset wrapper-chain collapse and optional `FlowSets` removal if still low risk after the first four streams.

## Risks

- Treasury finalization refactors can accidentally shift event timing or terminal side-effect ordering.
- Shared controller sync helpers can accidentally blur the meaningful differences between open and managed pruning policy.
- Routing canonicalization can regress the explicit no-premium path if any deployment site still recomputes policy independently.
- Strategy-base extraction can break clone/initializer behavior if constructor disablement changes.

## Verification

- Required:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `pnpm -s build:sizes`
- Completion workflow:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`
- Add focused regressions for any refactored lifecycle or deployment seam that lacks direct coverage.

## References

- `agent-docs/operations/completion-workflow.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/references/module-boundary-map.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`

## Outcome

- Added `TreasurySuccessAssertionMixin`, `BudgetControllerSyncLib`, and `ScopedSingleAllocatorStrategyBase`.
- Canonicalized open-budget risk routing through `IBudgetTCR.RiskModuleRouting` and removed the managed-preset wrapper-only initializer hop.
- Kept `FlowSets` unchanged after size review.
- Required post-simplify verification passed: `pnpm -s verify:required`, `pnpm -s build:sizes`, and `scripts/check-solidity-lint-baseline.sh`.
- Completion workflow executed with a worker simplify pass plus local fallback for coverage and finish-review after the audit subagents timed out.

# Child Sync Preview Requirements API

Status: complete
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Add a read-only `CustomFlow` preview helper that returns the budget-child sync witnesses required for a parent allocation update in ledger mode, including the expected child allocation commitment per required budget.

## Scope

- In scope:
  - Add `ChildSyncRequirement` + `previewChildSyncRequirements(...)` to `ICustomFlow`.
  - Implement preview logic in `CustomFlow` by mirroring existing `_maybeAutoSyncChildAllocations` and `_resolveChildSyncTarget` semantics.
  - Add focused tests in `FlowBudgetStakeAutoSync` for required/empty/unavailable and invalid parent witness cases.
- Out of scope:
  - Any behavior changes to allocation mutation, checkpointing, or child sync execution paths.
  - Changes under `lib/**`.

## Constraints

- Preserve existing witness/commit validation model.
- Preserve fail-open child target resolution semantics (`TARGET_UNAVAILABLE`/`NO_COMMITMENT`) in preview output shape by excluding non-required targets.
- Run required verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- Preview API compiles and is externally callable through `ICustomFlow`.
- Returned requirements match runtime required-child-sync behavior for changed budget allocations with non-zero child commits.
- Preview excludes unresolved targets and zero-commit child flows.
- Preview reverts on invalid/stale parent previous witness.

## Progress Log

- 2026-02-20: Plan created and scoped.
- 2026-02-20: Added `ICustomFlow.ChildSyncRequirement` and `previewChildSyncRequirements(...)` interface method.
- 2026-02-20: Implemented `CustomFlow.previewChildSyncRequirements` with strict previous-witness validation and ledger-mode account/weight resolution parity.
- 2026-02-20: Added focused `FlowBudgetStakeAutoSync` coverage for required target, empty cases, stale witness revert, and derived-key strategy resolution.
- 2026-02-20: Verified with `forge build -q` and `pnpm -s test:lite` (pass).

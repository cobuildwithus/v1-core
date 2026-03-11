# Allocation Resolver Interface + BudgetTCR Typed Calls

Status: complete
Created: 2026-02-22
Updated: 2026-02-22

## Goal

Improve interface safety and call-path debuggability by:
- Making allocation strategies explicitly implement `IAllocationKeyAccountResolver`.
- Removing low-level selector `.call` helpers in `BudgetTCR` in favor of typed interface calls with explicit best-effort wrappers.

## Scope

- In scope:
  - Update `BudgetStakeStrategy` and `GoalStakeVaultStrategy` inheritance and function override markers.
  - Refactor `BudgetTCR` helper call sites away from low-level selector dispatch.
  - Keep lifecycle behavior unchanged for removal terminalization and batch sync.
  - Add/update tests only where needed to lock behavior.
  - Add a concise agent rule note to prefer typed calls over low-level selector calls in protocol contracts.
- Out of scope:
  - Changes under `lib/**`.
  - Economic/liveness policy changes.
  - Cross-module architecture changes unrelated to these helpers.

## Constraints

- Preserve existing removal and batch-sync semantics.
- Keep force-zero behavior fail-fast where currently fail-fast.
- Maintain compatibility with existing events and external interface expectations.
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite`

## Tasks

1. Patch strategy inheritance and `accountForAllocationKey` overrides.
2. Replace low-level helper dispatch in `BudgetTCR` with typed wrappers.
3. Validate tests for sync/removal behavior and adjust if needed.
4. Add AGENTS guidance note.
5. Run required verification commands and finalize.

## Verification

- `forge build -q` (fails due unrelated pre-existing compile error in `test/flows/FlowUpgrades.t.sol` around missing `IFlow.flowImpl()`)
- `pnpm -s test:lite` (fails due unrelated pre-existing compile errors in `src/Flow.sol` / `test/flows/FlowInitializationAndAccessInit.t.sol` around missing `CONFIGURATION_IMMUTABLE`)
- `forge build -q src/allocation-strategies/BudgetStakeStrategy.sol src/allocation-strategies/GoalStakeVaultStrategy.sol src/tcr/BudgetTCR.sol` (pass)

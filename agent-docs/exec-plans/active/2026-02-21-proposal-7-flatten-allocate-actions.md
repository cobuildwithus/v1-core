# Proposal 7 - Flatten `allocate` Inputs with Strategy-Tagged Actions

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Replace strategy-aligned nested allocation arrays with a single action list so callers no longer depend on `fs.strategies` ordering or provide unused empty vectors.

## Scope

- In scope:
  - Update `ICustomFlow.allocate` to accept `AllocationAction[]`.
  - Refactor `CustomFlow.allocate` internals to execute action-by-action.
  - Enforce action strategy membership against configured flow strategies.
  - Migrate affected tests/helpers and docs.
- Out of scope:
  - Changes under `lib/**`.
  - Economic/lifecycle policy changes unrelated to calldata shape.

## Constraints

- Preserve commitment/witness allocation semantics and child-sync gating behavior.
- Preserve deterministic allocation effects and event emissions.
- Required verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- `allocate` no longer requires nested arrays aligned to configured strategy index.
- Per-action strategy, allocation data, and prior witness are explicit in calldata.
- Calls revert when an action references an unconfigured strategy.
- Existing allocation/child-sync behavior remains test-backed.

## Risks

- Helper/test migration churn can hide subtle regressions.
- Missing strategy-membership checks could admit unsupported action strategies.
- Multi-action ordering for repeated `(strategy,key)` updates must remain deterministic.

## Tasks

1. Update interface types/signature (`IFlow.sol`).
2. Refactor `CustomFlow.allocate` pipeline to flattened actions.
3. Add strict strategy-membership validation in `CustomFlow`.
4. Migrate helper/test callsites.
5. Update architecture/reference docs for new input model.
6. Run required verification.

## Progress Log

- 2026-02-21: Plan opened.
- 2026-02-21: Updated `ICustomFlow.allocate` to `AllocationAction[]` and added
  `ALLOCATION_STRATEGY_NOT_REGISTERED(address)`.
- 2026-02-21: Refactored `CustomFlow.allocate` execution loop to process flattened actions with per-action strategy
  membership checks.
- 2026-02-21: Post-change cleanup pass:
  - collapsed strategy registration check + cast into one resolver helper in `CustomFlow`,
  - deduplicated action-matrix length validation/counting in `WitnessCacheHelper`.
- 2026-02-21: Migrated flow test helpers/callsites to action-based allocate invocations and added validation coverage
  for unregistered strategy actions.
- 2026-02-21: Updated architecture/reference docs for action-based allocation shape and ordering semantics.

## Verification

- `forge build -q` (fails in pre-existing branch state):
  - `test/GeneralizedTCRGovernanceUpgrade.t.sol:101` missing
    `MockGeneralizedTCR.upgradeToAndCall` in pre-existing branch state, unrelated to this proposal's touched surfaces.
- `pnpm -s test:lite` (fails in the same pre-existing branch state compile blocker):
  - `test/GeneralizedTCRGovernanceUpgrade.t.sol:101` missing
    `MockGeneralizedTCR.upgradeToAndCall`.

# Single-Strategy Flow Surface Cutover

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Hard-cut the remaining Flow public surface from legacy multi-strategy shapes to a first-class single default-strategy ABI.

## Scope

- In scope:
  - Replace array-based Flow/managed-flow strategy getters and init params with singular default-strategy forms.
  - Remove redundant runtime strategy params from default-strategy-only `CustomFlow` sync/preview helpers.
  - Update child-flow deployment call sites, stack deployers, and readers to the singular strategy surface.
  - Update tests/harnesses/docs for the new ABI.
- Out of scope:
  - Changes under `lib/**`.
  - Behavior changes to allocation math, ledger checkpointing, or treasury lifecycle policy.
  - Compatibility shims for multi-strategy deployments.

## Constraints

- Preserve the existing single-strategy invariant already enforced at Flow initialization.
- Preserve allocation key derivation on the configured default strategy (`allocationKey(account, "")`).
- Preserve goal-ledger child-sync topology validation and fail-closed behavior.
- Keep TeamFlow self-strategy semantics intact while removing the one-element array wrapper.
- Required checks for Solidity changes: `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

## Acceptance Criteria

- Flow interfaces expose a singular configured strategy getter instead of `strategies()`.
- Flow initialization and child-flow creation accept one `IAllocationStrategy` value instead of one-element arrays.
- `CustomFlow` maintenance helpers no longer require callers to pass the default strategy redundantly.
- Factories/readers/tests compile and validate against the singular surface without behavior regressions.

## Risks

- Broad ABI changes can leave mocks/tests/helpers partially migrated if any `strategies()` stubs remain.
- Reader cutover must not weaken topology validation around child-flow strategy identity.
- Interface shape changes can require synchronized updates across deployer libraries and TeamFlow fixtures.

## Tasks

1. Cut over `IFlow`/`IManagedFlow`/`ICustomFlow` to singular default-strategy forms.
2. Refactor `Flow`, `CustomFlow`, `TeamFlow`, and flow deployment helpers to consume one strategy value.
3. Update stack deployers/readers (`GoalFactoryCoreStackDeploy`, `BudgetTCRStackActions`, goal-ledger readers, router strategy) to use the singular getter and default-only sync helpers.
4. Update impacted tests/harnesses/docs for the ABI break.
5. Run required verification and completion workflow audits.

## Progress Log

- 2026-03-10: Plan opened.
- 2026-03-10: Completed singular strategy getter/param cutover across Flow, TeamFlow, readers, deployers, and tests.
- 2026-03-10: Added regression coverage for removed legacy strategy-parameter maintenance selectors.

## Verification

- `forge build -q`
- `forge test --match-path test/flows/GoalFlowLedgerModeValidation.t.sol`
- `forge test --match-path test/flows/FlowAllocationsLifecycle.t.sol`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s verify:required`

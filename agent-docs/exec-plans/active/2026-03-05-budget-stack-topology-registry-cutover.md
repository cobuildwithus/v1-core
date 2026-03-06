# 2026-03-05 Budget Stack Topology Registry Cutover

## Goal

Make `BudgetTCR` the canonical budget-stack topology registry so budget-domain consumers stop rediscovering topology from runtime graph probes, while preserving lightweight runtime fail-closed cross-checks where they materially protect correctness.

## Scope

- Add a dedicated read interface for canonical budget-stack topology.
- Extend `BudgetTCR` deployment storage with the runtime addresses needed to expose that topology directly.
- Reorder budget stack activation so topology is recorded before `BudgetStakeLedger.registerBudget(...)`.
- Refactor `BudgetStakeLedger` registration validation to read topology from the registry and keep a minimal runtime consistency check.
- Refactor `GoalFlowLedgerMode` child-sync target resolution to read topology via `budgetTreasury.authority() -> BudgetTCR`, while still verifying the child flow's actual default strategy matches the stored topology.
- Update targeted tests and architecture docs for the new topology ownership model.

## Non-Goals

- Do not change `Flow.sol` or generic flow initialization/runtime rules.
- Do not change `BudgetFlowRouterStrategy` routing semantics.
- Do not add backward-compat storage shims for pre-existing live deployments.

## Invariants To Preserve

- `BudgetTCR` remains the authority/controller for deployed budget treasuries.
- Child flows still initialize with exactly one allocation strategy.
- Child-sync remains fail-closed on unresolved or mismatched topology/strategy state.
- Budget registration still rejects malformed or miswired budget treasuries.
- Removed/inactive stacks remain discoverable for terminalization/pruning flows, but active-state checks remain explicit.
- Exact-byte relists stay fail-closed once an `itemID` has ever produced a deployed stack; only pre-activation removals may be resubmitted with the same item hash.

## Planned Changes

1. Canonical topology surface:
   - Add `IBudgetStackTopologyReader`.
   - Make `IBudgetTCR` extend the new reader interface.
   - Expose topology getters and reverse lookups from `BudgetTCR`.
2. Deployment/storage cutover:
   - Extend `BudgetTCRStorageV1.BudgetDeployment` with `premiumEscrow` and `allocationMechanismArbitrator`.
   - Add `_itemIdByChildFlow`.
   - Record topology in activation before ledger registration.
3. Consumer cutover:
   - `BudgetStakeLedger.registerBudget(...)` reads topology from `msg.sender` and validates it against the treasury/runtime.
   - `GoalFlowLedgerMode` resolves budget child-sync targets from registry topology discovered through `ITreasuryAuthority.authority()`.
4. Tests/docs:
   - Update unit/property tests and harnesses that currently mock `budgetTreasury.flow()` / `childFlow.strategies()` as the sole topology source.
   - Update architecture/spec docs to describe `BudgetTCR` as the canonical topology owner.
   - Encode the chosen relist rule in `BudgetTCR`: reject exact-byte relists after any deployed stack exists for the item hash, while still allowing pre-activation re-submission.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes after implementation:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

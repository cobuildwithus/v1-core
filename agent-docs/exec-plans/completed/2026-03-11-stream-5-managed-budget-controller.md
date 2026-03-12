# 2026-03-11 Stream 5 Managed Budget Controller

Status: completed
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Add the managed-goal runtime controller that owns budget topology, keeps Safe authority separate from allocator identity, and drives goal-flow allocation as the controller contract.

## Scope

- In scope:
  - `src/goals/ManagedBudgetController.sol`
  - `test/goals/ManagedBudgetController.t.sol`
  - controller-local helper interfaces/structs inside the controller file when that avoids overlap with active shared-abstraction streams
- Out of scope:
  - factory preset wiring
  - shared `IBudgetController` / `IBudgetGatePolicy` / `SingleAllocatorStrategy` extraction already owned by other active streams
  - deep open-goal `BudgetTCR` changes

## Constraints

- Controller contract address must remain the allocator identity; Safe authority changes must not change that allocator identity.
- Reuse existing lifecycle helpers where possible:
  - `BudgetTCRTerminalActions`
  - `BudgetTCRStackDeploymentLib`
- Do not add TCR-only or advisory-mechanism behavior.
- Avoid edits to files already owned by Streams 1/2/3/4/6 unless a clean isolated implementation becomes impossible.

## Intended shape

1. `ManagedBudgetController` stores:
   - `authority` / `pendingAuthority`
   - `goalTreasury`
   - `goalFlow`
   - `budgetAllocationLedger`
   - `stackDeployer`
   - `budgetGatePolicy`
   - budget deployment topology / reverse lookups / active item tracking
2. `createBudget(...)`:
   - asks stack deployer for prepared strategy / treasury / escrow anchors
   - adds child flow recipient with Safe as child `recipientAdmin`
   - initializes budget treasury via shared deployment lib through the stack deployer
   - records topology and registers the budget in the allocation ledger if configured
3. `removeBudget(...)`:
   - removes the budget from the allocation ledger
   - removes the child recipient from goal flow
   - pre-activation: strict fail-close terminalization
   - activated: stop flow immediately and leave treasury on normal terminal lifecycle
4. `setBudgetWeights(...)`:
   - authority-only
   - validates all item ids are active
   - calls `goalFlow.allocate(...)` from the controller contract
5. `syncBudgetTreasuries(...)`:
   - permissionless batch
   - optional best-effort gate-policy call before per-budget `sync()`
6. `pruneTerminalBudget(...)`:
   - permissionless
   - removes terminal recipient if still present
   - best-effort goal treasury sync

## Test plan

- multiple managed budgets can be created and tracked
- weight updates route through controller-owned allocator identity
- authority rotation changes Safe authority but not allocator identity
- terminal pruning works through the generic controller surface
- batch sync continues across gate-policy or treasury failures

## Notes for follow-on streams

- Stream 6 factory wiring assumption: the current managed preset still points at a temporary `ManagedBudgetControllerStackDeployer` stub, so preset-created managed goals should not be treated as budget-creation-ready until Stream 4 / 6 lands the real deployer or explicitly gates the preset as unsupported for live budget creation.
- Authority rotation is intentionally controller-local: it updates `ManagedBudgetController.authority()` only. It does not mutate `SingleAllocatorStrategy.allocator()` and it does not rewrite already-created child-flow `recipientAdmin` authorities.
- `bytes32(0)` is now reserved as the controller's internal "not found" sentinel. Stream 6 wiring and any caller-facing UX should reject zero managed-budget item ids before calling `createBudget(...)`.
- Helper/library extraction I intentionally did not add: a shared managed-stack deployer test harness or a neutral controller-topology lookup helper. Both would reduce duplication, but they would have widened this stream into files actively owned by other streams.

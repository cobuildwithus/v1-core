# 2026-03-11 Managed Goal Preset Integration

Status: completed
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Integrate stream outputs for open-market and managed-maintainer goal presets without changing the frozen architecture.
- Resolve interface drift across controller, deployer, factory, and allocation seams.
- End with compiling code plus coherent preset regression coverage.

## Constraints

- Preserve the master-plan invariants:
  - controller contract remains allocator identity,
  - Safe rotation does not change allocator identity,
  - `StakeVault` remains the funding vault,
  - managed runtime paths do not depend on underwriter-weight semantics,
  - open-goal behavior remains current production semantics.
- Do not add `if (isManaged)` runtime branches in neutral substrate modules.
- Prefer one small shared abstraction or helper over preset-specific hacks.

## Working Scope

- Reconcile shared interface and deployer surfaces introduced by Streams 1, 3, 4, 5, and 6.
- Fix factory preset wiring so both open and managed presets deploy from one substrate.
- Add or repair targeted tests covering:
  - open preset regression,
  - managed preset end-to-end deployment,
  - multiple managed budgets and live weight updates,
  - null premium escrow behavior,
  - single-allocator goal-flow ledger behavior,
  - terminal prune parity across `BudgetTCR` and `ManagedBudgetController`.

## Risks

- `GoalFactory.sol` and factory helper libraries remain the hottest merge seam.
- `BudgetTreasury` / `IBudgetController` / topology reader interfaces can drift silently if open and managed controllers expose slightly different runtime assumptions.
- Managed stack deployer glue must compose Stream 4’s modular stack APIs without reintroducing open-specific assumptions.

## Plan

1. Build/targeted-test the current tree to surface compile and interface drift.
2. Patch the smallest shared seams needed for factory/controller/deployer compatibility.
3. Repair or add preset regression tests until open and managed flows are coherently covered.
4. Run required Solidity verification and completion-workflow audit passes before handoff.

## Current Focus

- Add a real-component managed budget creation test that exercises `ManagedBudgetController -> ManagedBudgetControllerStackDeployer -> BudgetTreasury -> NullPremiumEscrow -> child flow` in one path.
- Add direct authorization/guard tests for `BudgetSingleAllocatorStrategy` and `ManagedBudgetControllerStackDeployer`.
- Pin the managed preset zero-premium/zero-slash guard on both nonzero branches before final verification.

## Outcome

- Managed preset now deploys a real budget stack through `ManagedBudgetControllerStackDeployer` using cloned `BudgetTreasury` and `NullPremiumEscrow` plus `BudgetSingleAllocatorStrategy` for budget child flows.
- Factory-managed bootstrap now sources the `BudgetTreasury` implementation from BudgetTCR deployer metadata so managed goals can create budgets end-to-end.
- Managed goal-level allocator strategy ownership is now bound to the controller contract itself, so Safe authority rotation cannot retake allocator identity through `SingleAllocatorStrategy.changeAllocator()`.
- Managed preset now rejects zero budget-assertion liveness at deploy time instead of allowing a controller that cannot create budgets later.
- Managed preset premium/slash validation is pinned by regression tests, while open preset deployment semantics remain covered by existing factory regression tests.

## Verification

- `forge test --match-contract 'ManagedBudgetController(Test|RealStackTest)|ManagedBudgetControllerStackDeployerTest|BudgetSingleAllocatorStrategyTest|GoalFactoryUnderwritingSlashConfigGuardTest|GoalFactorySpendPolicyDeployTest'`
- `forge test --match-contract 'BudgetTCRManagedStackDeploymentsTest|SingleAllocatorStrategyTest'`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

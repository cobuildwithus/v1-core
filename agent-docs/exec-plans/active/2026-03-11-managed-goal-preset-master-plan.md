# 2026-03-11 Managed Goal Preset Master Plan

## Frozen Summary

- Deployment-time presets select control-plane modules. Runtime paths must not branch on `isManaged`.
- `StakeVault` remains the funding vault for both open and managed goals.
- Open goals keep the current open-market stack and semantics.
- Managed maintainer goals freeze these shared names:
  - `IBudgetController`
  - `IBudgetGatePolicy`
  - `ManagedBudgetController`
  - `IGoalScopedAllocationStrategy`
  - `SingleAllocatorStrategy`
- Managed goal allocator identity is the controller contract, not the Safe directly.
- Managed goals use `ManagedBudgetController`, `SingleAllocatorStrategy`, and no premium module by default.
- Managed budget child `recipientAdmin` is the Safe directly in v1.
- No advisory TCR for maintainer goals in this pass.
- Do not add a managed mechanism controller in this pass.

## Goal

Refactor the protocol so recursive flows stay the neutral substrate while open-market and managed-maintainer control planes become deployment-time pluggable modules. This planning pass freezes shared names, interfaces, boundaries, and stream ownership only. It does not change runtime behavior.

## Non-Negotiable Invariants

1. Controller contract is allocator identity.
   - For managed goals, the allocator recognized by goal allocation strategy logic is the controller contract.
   - The Safe can remain admin for child recipient operations in v1, but it is not the allocator identity.
2. Goal-flow allocation pipeline is strategy-agnostic.
   - Goal-flow allocation checkpointing and child-sync must depend on a generic goal-scoped allocation strategy boundary, not on `StakeVault` specifics.
   - `StakeVault` is one strategy implementation; `SingleAllocatorStrategy` is another.
3. Budget routing is separate from budget coverage/gating.
   - Controller modules own parent/child routing, terminal prune, and goal sync retry decisions.
   - Gate policy modules own whether a budget should be enabled/disabled and how coverage/cap checks are derived.
4. `BudgetTreasury` depends on a generic controller interface, not `IBudgetTCR`.
   - `BudgetTreasury` may know that its `controller` implements `IBudgetController`.
   - `BudgetTreasury` must not hard-code `IBudgetTCR` as its terminal-prune dependency.

## Frozen Module Boundaries

### Neutral substrate

- `src/Flow.sol`, `src/flows/CustomFlow.sol`, `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
- `src/goals/GoalTreasury.sol`, `src/goals/BudgetTreasury.sol`, `src/goals/StakeVault.sol`
- These modules remain preset-agnostic runtime substrate. They can depend on generic interfaces, but they must not branch on managed/open preset selection.

### Open-goal control plane

- `BudgetTCR` remains the open-goal controller/topology owner.
- Open goals keep the current open-market semantics, including current budget listing, gating, premium escrow, and mechanism-registry behavior.
- Open goals continue to use the current premium escrow path, not the managed preset path.

### Managed-goal control plane

- `ManagedBudgetController` is the deployment-time controller alternative for maintainer goals.
- `ManagedBudgetController` owns managed budget topology, terminal prune behavior, and controller-side goal-sync retry behavior.
- `ManagedBudgetController` delegates coverage/gating decisions to a pluggable `IBudgetGatePolicy`.
- Managed goals use explicit no-premium mode (`PremiumEscrowMode.None` / `address(0)`), not a shim contract.
- This pass does not add any managed analogue of `AllocationMechanismTCR`.

### Allocation boundary

- Freeze `IGoalScopedAllocationStrategy` as the goal-flow strategy boundary for controller-owned allocator identity.
- `SingleAllocatorStrategy` is the managed-goal implementation of that boundary.
- `StakeVault` remains the open-goal/live-stake implementation of that boundary.
- The allocation pipeline must consume the shared strategy boundary and stay unaware of which concrete strategy is wired at deployment.

### Budget gating boundary

- `IBudgetGatePolicy` owns credit-line / coverage / enable-disable policy only.
- Controller modules execute routing writes such as recipient enablement, terminal prune, and goal sync.
- No gate policy should own budget treasury lifecycle or treasury custody.

### Escrow boundary

- Open preset: current premium escrow stack remains unchanged.
- Managed preset: no premium module by default. Use explicit `PremiumEscrowMode.None` / `address(0)` wiring.

## Frozen Shared Interface and Contract Names

### `IBudgetController`

- Shared controller boundary implemented by `BudgetTCR` and `ManagedBudgetController`.
- `BudgetTreasury` controller interactions must route through this name.
- Freeze the existing terminal-prune method name on the generic boundary:
  - `pruneTerminalBudget(address budgetTreasury) returns (bool removedFromParent, bool goalSynced)`
- Minimum frozen responsibility:
  - terminal recipient prune from parent goal flow
  - best-effort goal treasury sync trigger after prune when applicable
  - controller identity exposed as the allocator identity for managed goals
- Keep this interface generic. Do not leak open-market-only concepts such as TCR listing state into it.

### `IBudgetGatePolicy`

- Shared budget gating policy boundary used by controller implementations.
- Policy evaluates whether a budget should remain enabled and what cap/coverage inputs matter.
- Policy must be pluggable and independently replaceable from the controller.
- `BudgetTreasury` is not a consumer of this interface.

### `ManagedBudgetController`

- Concrete managed-goal controller for maintainer preset budgets.
- Must satisfy `IBudgetController`.
- Must be the allocator identity seen by `SingleAllocatorStrategy`.
- Must not grow managed mechanism-registry ownership in this pass.

### Optional premium module

- Managed goals represent premium-module absence explicitly through `PremiumEscrowMode.None` / `address(0)`.
- Runtime consumers must treat the premium/risk module as optional rather than depending on a fake escrow implementation.

### `IGoalScopedAllocationStrategy`

- Frozen name for the goal-flow strategy boundary that separates allocation identity/rules from the allocation pipeline.
- This may extend or replace the current generic strategy surface, but parallel streams must not invent a second competing goal-scoped strategy name.
- If implementation keeps `IAllocationStrategy` as the underlying runtime shape, document `IGoalScopedAllocationStrategy` as the canonical domain name and keep semantics aligned.

### `SingleAllocatorStrategy`

- Concrete managed-goal strategy that admits exactly one allocator identity: the controller contract.
- Safe admin permissions do not change this identity rule.
- This strategy is for managed goals only; it must not be introduced as an `isManaged` branch inside existing open-goal strategy code.

## Deployment-Time Preset Freeze

### Open goal preset

- Goal funding vault: `StakeVault`
- Goal allocation strategy: stake-vault-based strategy
- Budget controller: `BudgetTCR`
- Budget gate policy: current open-market credit/cap policy
- Premium escrow: current premium escrow implementation
- Mechanism controller: existing open-market mechanism registry path

### Managed maintainer-goal preset

- Goal funding vault: `StakeVault`
- Goal allocation strategy: `SingleAllocatorStrategy`
- Allocator identity: controller contract
- Budget controller: `ManagedBudgetController`
- Budget gate policy: pluggable `IBudgetGatePolicy`
- Premium escrow: none by default (`PremiumEscrowMode.None`)
- Budget child `recipientAdmin`: Safe directly in v1
- Advisory TCR: none in this pass
- Managed mechanism controller: none in this pass

## Stream Ownership

### Stream A: controller interface cutover

- Owns:
  - `src/interfaces/IBudgetController.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/interfaces/IBudgetTreasury.sol`
  - `src/tcr/interfaces/IBudgetTCR.sol`
  - `src/tcr/BudgetTCR.sol`
  - targeted tests/docs for controller-interface migration
- Responsibility:
  - replace `BudgetTreasury -> IBudgetTCR` dependency with `BudgetTreasury -> IBudgetController`
  - make `BudgetTCR` satisfy the generic controller boundary without changing open-goal behavior
- Must not own:
  - managed controller logic
  - allocation-strategy rewiring
  - factory preset selection

### Stream B: goal-scoped allocation strategy cutover

- Owns:
  - `src/interfaces/IGoalScopedAllocationStrategy.sol` or the documented adapter/canonicalization point to current strategy interface
  - `src/allocation-strategies/SingleAllocatorStrategy.sol`
  - `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
  - `src/interfaces/IAllocationStrategy.sol` if required for the canonical cutover
  - `src/goals/StakeVault.sol`
  - targeted tests/docs for goal-flow strategy generalization
- Responsibility:
  - make the goal-flow allocation pipeline strategy-agnostic
  - keep `StakeVault` and `SingleAllocatorStrategy` on the same goal-scoped strategy contract
- Must not own:
  - budget controller/gate policy design
  - deployment preset plumbing

### Stream C: managed controller and gate policy

- Owns:
  - `src/interfaces/IBudgetGatePolicy.sol`
  - `src/goals/ManagedBudgetController.sol`
  - any small controller-owned helper libraries introduced for managed gating
  - targeted tests/docs for managed controller behavior
- Responsibility:
  - implement managed budget routing/control without TCR semantics
  - keep budget routing separate from gate policy evaluation
  - preserve explicit no-premium wiring through `PremiumEscrowMode.None`
- Must not own:
  - open-goal controller behavior changes beyond satisfying `IBudgetController`
  - managed mechanism-controller work

### Stream D: factory and deployment preset wiring

- Owns:
  - `src/goals/GoalFactory.sol`
  - `src/goals/library/GoalFactoryCoreStackDeploy.sol`
  - `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`
  - any new preset-selection structs/helpers under `src/goals/library/**`
  - end-to-end deployment tests/docs
- Responsibility:
  - make deployment choose open vs managed preset tuples explicitly
  - wire the managed preset modules without adding hidden runtime preset branching
- Must not own:
  - deep controller internals from Stream C
  - strategy-pipeline internals from Stream B

## Risky Seams / Expected Merge Conflicts

- `src/goals/GoalFactory.sol` and `src/goals/library/GoalFactory*.sol` are already hot deployment surfaces and are the most likely merge-conflict area.
- `src/goals/BudgetTreasury.sol`, `src/tcr/BudgetTCR.sol`, and `src/tcr/interfaces/IBudgetTCR.sol` are tightly coupled today and will conflict if Stream A and Stream C drift on controller responsibilities.
- `src/hooks/GoalFlowAllocationLedgerPipeline.sol`, `src/interfaces/IAllocationStrategy.sol`, and `src/goals/StakeVault.sol` are the hot seam for keeping the allocation pipeline strategy-agnostic.
- Any attempt to make managed goals work by zero-address escrow wiring, direct Safe allocator identity, or `isManaged` branching should be treated as out of bounds for this refactor.

## Working Rule For Later Streams

- Before code changes, each implementation stream must add its own row to `COORDINATION_LEDGER.md`.
- If a stream needs to rename any frozen name above, it must first update this master plan with a concrete reason and explicit downstream migration owner.

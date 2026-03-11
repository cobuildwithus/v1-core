# 2026-03-11 Stream 1 Goal Allocator Generalization

Status: completed
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Make the goal-flow allocation ledger pipeline strategy-agnostic so open goals can keep `StakeVault` and managed goals can use `SingleAllocatorStrategy` without stake-vault-specific assumptions in neutral substrate code.

## Acceptance criteria

- Goal-ledger validation no longer requires strategies to expose `stakeVault()` for allocator ownership checks.
- Validation instead proves strategy-to-goal ownership through a goal-scoped strategy boundary shared by `StakeVault` and `SingleAllocatorStrategy`.
- Goal-ledger preview/checkpoint paths resolve allocator weight via strategy calls rather than direct `IStakeVault.weightOf(account)` reads.
- Reverse allocation-key lookup still round-trips for both `StakeVault` and `SingleAllocatorStrategy`.
- `SingleAllocatorStrategy` uses the controller-contract address as allocator identity and preserves that identity if Safe/owner authority later changes.
- Open-goal `StakeVault` allocator behavior and child-sync semantics remain unchanged.

## Scope

- In scope:
  - `src/library/GoalFlowLedgerMode.sol`
  - `src/hooks/GoalFlowAllocationLedgerPipeline.sol`
  - `src/interfaces/IGoalLedgerStrategy.sol`
  - `src/interfaces/IGoalScopedAllocationStrategy.sol`
  - `src/interfaces/IHasStakeVault.sol` if needed for deprecation-only narrowing
  - `src/allocation-strategies/SingleAllocatorStrategy.sol`
  - targeted tests covering `StakeVault`, `SingleAllocatorStrategy`, allocator key round-trip, and controller-vs-Safe identity
- Out of scope:
  - factory/deployment preset wiring
  - managed controller/gate-policy implementation
  - changing open-goal runtime semantics beyond the shared strategy boundary

## Constraints

- No `isManaged` branching in neutral substrate code.
- Do not break `StakeVault` as the open-goal allocator strategy.
- Prefer address-key allocation identity; do not use a fixed allocation key of `0`.
- Keep blast radius small and preserve existing external interfaces where possible.

## Tasks

1. Add the canonical goal-scoped allocation strategy interface and align goal-ledger aliases to it.
2. Refactor `GoalFlowLedgerMode` / pipeline validation and weight resolution away from stake-vault-specific assumptions.
3. Implement `SingleAllocatorStrategy` on the shared goal-scoped boundary with controller-contract allocator identity.
4. Add or update targeted flow/strategy tests for both strategy families and allocator identity invariants.
5. Run required verification and completion-workflow passes.

## Decisions

- Use `goalTreasury()` as the strategy-to-goal ownership relation because both `StakeVault` and `SingleAllocatorStrategy` can expose it without preset-specific branching.
- Use address-key allocation identity so controller-contract allocator identity naturally round-trips through `allocationKey(account, "")` and `accountForAllocationKey(...)`.

## Verification plan

- Targeted Forge tests for goal-ledger mode, child-sync pipeline behavior, and `SingleAllocatorStrategy`.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

## Notes for follow-on streams

- Stream 6 will need to wire managed preset deployment so `SingleAllocatorStrategy` is instantiated with the managed controller contract as allocator identity and with the correct goal treasury for goal-scoped validation.
- Final verification on the completed change set passed with `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

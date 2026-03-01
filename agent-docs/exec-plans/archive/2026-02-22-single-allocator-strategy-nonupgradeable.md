# Single Allocator Strategy Non-Upgradeable Refactor

Status: active
Created: 2026-02-22
Updated: 2026-02-22

## Goal

- Remove UUPS/proxy-style upgrade surface from `SingleAllocatorStrategy` and keep a minimal direct-deploy allocator gate strategy.

## Acceptance criteria

- `SingleAllocatorStrategy` no longer imports/inherits UUPS or upgradeable-ownable modules.
- Strategy initialization is constructor-based (no external `initialize`).
- Owner-only allocator mutation remains available through a simple setter.
- Upgrade-specific tests/artifacts for this strategy are removed.
- Baseline verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - `src/allocation-strategies/SingleAllocatorStrategy.sol`
  - `test/flows/SingleAllocatorStrategy.t.sol`
  - `test/upgrades/SingleAllocatorStrategyTestUpgrade.sol`
  - architecture/security docs reflecting removed upgrade surface
- Out of scope:
  - changes under `lib/**`
  - flow runtime proxy model changes

## Constraints

- Keep strategy behavior unchanged for allocation keying/weight checks.
- Keep owner-gated allocator updates and zero-address guard.

## Tasks

1. Refactor `SingleAllocatorStrategy` to direct-deploy `Ownable` constructor initialization.
2. Replace `changeAllocator` with `setAllocator` owner-only mutator.
3. Update strategy tests for constructor deployment and remove upgrade checks.
4. Update architecture/security docs for removed strategy upgrade path.
5. Run build and lite tests.

## Decisions

- Use `Ownable` constructor (`Ownable(_initialOwner)`) instead of initializer flow to fully remove proxy initialization semantics.
- Keep allocator mutability (owner-only `setAllocator`) while dropping all strategy implementation upgrade paths.

## Progress log

- 2026-02-22: Refactored `SingleAllocatorStrategy` from UUPS + initializer to constructor-based `Ownable` runtime contract.
- 2026-02-22: Updated strategy tests to direct deployment and removed upgrade-path assertions.
- 2026-02-22: Removed obsolete `test/upgrades/SingleAllocatorStrategyTestUpgrade.sol`.
- 2026-02-22: Updated architecture/security docs to state allocation strategies are direct deployments without runtime upgrades.
- 2026-02-22: Verification run completed; strategy-focused tests pass, repo lite suite currently has two existing failing tests outside this change scope.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (fails on two existing tests unrelated to strategy refactor):
  - `test/flows/CustomFlowRewardEscrowCheckpoint.t.sol::test_allocate_succeedsWhenHookConfiguredWithoutLedger`
  - `test/goals/RewardEscrow.t.sol::test_checkpointAllocation_onlyGoalFlow`
- `forge test --match-path test/flows/SingleAllocatorStrategy.t.sol` (pass)

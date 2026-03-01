# Escrow And Allocator Optional Cleanups

Status: active
Created: 2026-02-20
Updated: 2026-02-20

## Goal

- Apply the requested optional simplifications while preserving current payout and access-control behavior:
  - switch `SingleAllocatorStrategy.changeAllocator` to custom-error style,
  - remove duplicate zero-claim emission blocks in `RewardEscrow.claim`,
  - cache successful points per account for repeated rent claims.

## Acceptance criteria

- `changeAllocator(address)` reverts with `ADDRESS_ZERO()` on zero address input.
- `RewardEscrow.claim` uses a shared zero-claim helper and preserves existing four-event emission semantics.
- `RewardEscrow.claim` computes successful points once per account and reuses the cached value on later claims.
- Baseline verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - `src/allocation-strategies/SingleAllocatorStrategy.sol`
  - `src/goals/RewardEscrow.sol`
  - `test/flows/SingleAllocatorStrategy.t.sol`
- Out of scope:
  - Changes under `lib/**`.
  - Reward model redesign or interface surface changes outside the requested cleanup.

## Constraints

- Preserve claim behavior and event coverage used by integration tests.
- Keep changes localized and low-risk.

## Tasks

1. Replace string `require` in allocator change path with custom error revert.
2. Extract shared claim helpers to reduce duplicate zero-claim blocks.
3. Add successful-points cache in escrow claim path.
4. Run build and lite regression suite.

## Decisions

- Cache `userSuccessfulPoints` on first claim per account because post-finalization successful-point accounting is stable for the escrow lifecycle.

## Progress log

- 2026-02-20: Updated `SingleAllocatorStrategy.changeAllocator` to custom error and aligned test expectation.
- 2026-02-20: Refactored `RewardEscrow.claim` with `_markClaimed` and `_emitZeroClaim` helpers.
- 2026-02-20: Added `_successfulPointsCached`/`_successfulPoints` state and `_successfulPointsFor` helper.
- 2026-02-20: Verification passed (`forge build -q`, `pnpm -s test:lite`).

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass)

# Ledger Sync Checkpoint Unification (Allocate + Permissionless Sync)

Status: completed
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Unify budget-ledger checkpointing across all allocation mutation paths so stake-weight changes (including slashing) are reflected when allocations are permissionlessly synchronized, not only when allocators call `allocate`.

## Acceptance criteria

- `CustomFlow.allocate` and `CustomFlow.syncAllocationCompact/clearStaleAllocation` both route through the same ledger-checkpoint logic when allocation ledger mode is enabled.
- Permissionless sync paths derive checkpoint account identity from allocation key via strategy key->account resolver.
- Existing commitment/witness invariants remain unchanged.
- Reward-escrow integration tests assert that permissionless sync updates ledger stake after slash.
- Required verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - `src/flows/CustomFlow.sol`
  - allocation strategies used with address-keyed stake (`src/allocation-strategies/BudgetStakeStrategy.sol`, `src/allocation-strategies/GoalStakeVaultStrategy.sol`)
  - test strategy resolver support (`test/mocks/MockAllocationStrategy.sol`)
  - reward escrow integration regression (`test/goals/RewardEscrowIntegration.t.sol`)
- Out of scope:
  - Full redesign of `BudgetStakeLedger` state model.
  - Changes under `lib/**`.

## Constraints

- Preserve existing external commitment/witness format and allocation semantics.
- Keep fail-closed behavior in ledger mode.
- No changes to submodules or `lib/**`.

## Tasks

1. Add strategy key->account resolver interface usage in `CustomFlow` ledger checkpoint path.
2. Refactor allocation mutation internals to use a shared apply+checkpoint path for both allocate and sync/clear-stale.
3. Implement resolver function on relevant strategies/mocks.
4. Update slashing integration test to assert permissionless sync checkpointing.
5. Run required verification.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (pass, 682 tests)

## Follow-up risk

- `allocate` currently checkpoints ledger stake for `msg.sender`, while permissionless sync derives account from allocation key. This is safe for address-keyed strategies but should be unified if non-address-keyed strategies ever run in ledger mode.

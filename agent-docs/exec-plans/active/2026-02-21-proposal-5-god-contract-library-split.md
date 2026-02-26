# Proposal 5 - Goal/Reward God-Contract Internal Library Split

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Refactor `GoalStakeVault` and `RewardEscrow` into thinner orchestrators by extracting high-risk math/bookkeeping into internal libraries while preserving all externally observable behavior (ABI, state transitions, events, and rounding).

## Scope

- In scope:
  - Add internal libraries for:
    - `BudgetStakeLedger` accrual/warmup math helpers.
    - `RewardEscrow` claim/rent-index math helpers.
    - `GoalStakeVault` rent accrual math.
    - `GoalStakeVault` juror/slashing math helpers.
  - Rewire `src/goals/GoalStakeVault.sol`, `src/goals/RewardEscrow.sol`, and `src/goals/BudgetStakeLedger.sol` to call those libraries.
  - Keep external/public function signatures unchanged.
  - Add property-style math tests and differential tests against an in-test reference model using deterministic fuzz seeds.
- Out of scope:
  - Interface changes under `src/interfaces/**`.
  - Economic policy changes.
  - Any edits under `lib/**`.

## Constraints

- Preserve order-of-effects for transfer/state update paths.
- Preserve exact rounding semantics (`Math.mulDiv` usage and capping behavior).
- Preserve existing revert selectors and state guards.
- Required verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- `GoalStakeVault` and `RewardEscrow` delegate extracted math/bookkeeping to internal libraries.
- `BudgetStakeLedger` accrual math is extracted and reused.
- Existing tests pass unchanged.
- New tests cover:
  - monotonicity/bounds/no-underflow style properties for extracted math.
  - differential parity between extracted-library output and reference legacy formulas.

## Risks

- Rounding/order drift during extraction could subtly alter payouts/slashing/rent.
- Library API design can accidentally reorder effects if state/transfer boundaries blur.
- Differential tests can miss edge cases if they do not mirror legacy formulas exactly.

## Progress Log

- 2026-02-21: Plan opened.
- 2026-02-21: Added extracted goal-domain math libraries:
  - `src/goals/library/BudgetStakeLedgerMath.sol`
  - `src/goals/library/RewardEscrowMath.sol`
  - `src/goals/library/GoalStakeVaultRentMath.sol`
  - `src/goals/library/GoalStakeVaultJurorMath.sol`
  - `src/goals/library/GoalStakeVaultSlashMath.sol`
- 2026-02-21: Rewired contracts to call extracted libraries while preserving ABI and external entrypoint semantics:
  - `src/goals/BudgetStakeLedger.sol`
  - `src/goals/RewardEscrow.sol`
  - `src/goals/GoalStakeVault.sol`
- 2026-02-21: Added differential/property-focused math tests:
  - `test/goals/BudgetStakeLedgerMath.t.sol`
  - `test/goals/RewardEscrowMath.t.sol`
  - `test/goals/GoalStakeVaultMath.t.sol`
- 2026-02-21: Updated architecture/module docs for new goal-domain library boundaries.
- 2026-02-21: Post-change cleanup:
  - removed unused test harness contracts in the new math test files,
  - simplified `GoalStakeVault` rent-preview helper signature (pass checkpoint directly).

## Verification

- Targeted focused checks (pass):
  - `forge test -q --match-path "test/goals/*Math.t.sol"`
  - `forge test -q --match-path test/goals/GoalStakeVault.t.sol`
  - `forge test -q --match-path test/goals/RewardEscrow.t.sol`
  - `forge test -q --match-path test/goals/BudgetStakeLedgerEconomics.t.sol`
- Full required verification (pass):
  - `forge build -q`
  - `pnpm -s test:lite`

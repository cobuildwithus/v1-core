# Proposal 7 Testing Hard Subsystems

Status: complete
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Add high-value invariant/property tests for the three hardest protocol subsystems: flow allocation commitments/units, ledger-mode child-sync witness gating, and BudgetStakeLedger economics/finalization behavior.

## Scope

- In scope:
  - Add flow allocation property tests for commitment hashing, exact touched-recipient unit outcomes, and invalid witness rejection.
  - Add ledger-mode child-sync property tests for single checkpoint call behavior and witness-required gating keyed by child commit presence.
  - Add BudgetStakeLedger economics property tests for monotonic points, conservation-style upper bounds under reallocation, and finalize sealing behavior.
- Out of scope:
  - Contract production logic changes under `src/**` unless needed for test-only compatibility.
  - Any changes under `lib/**`.

## Constraints

- Preserve existing protocol behavior; tests should characterize current guarantees without introducing compatibility shims.
- Reuse existing test harness patterns where possible (`FlowTestBase`, witness cache helpers).
- Verification required before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

- New tests compile and execute in the repo’s standard suites.
- Flow tests prove canonical commit hash and exact unit-accounting outcomes for touched recipients.
- Ledger-mode tests prove checkpoint exactly-once per successful allocation and witness requirement iff changed stake + non-zero child commit.
- BudgetStakeLedger tests prove monotonic accrual under fixed allocation, no points inflation beyond raw stake-time bound under reallocations, and post-finalize checkpoint immutability/no-op behavior.

## Progress log

- 2026-02-20: Created active execution plan and scoped the three test tracks.
- 2026-02-20: Added `test/flows/FlowAllocationProperties.t.sol` with fuzz-property coverage for canonical commit hashing, touched-recipient unit accounting, and invalid witness rollback guarantees.
- 2026-02-20: Added `test/flows/FlowLedgerChildSyncProperties.t.sol` with fuzz-property coverage for single-call ledger checkpointing and child-sync witness requirement iff changed stake + non-zero child commit.
- 2026-02-20: Added `test/goals/BudgetStakeLedgerEconomics.t.sol` with fuzz-property coverage for monotonic accrual, stake-time conservation bounds, and finalize sealing behavior.
- 2026-02-20: Verification:
  - `forge build -q` passed.
  - `pnpm -s test:lite` failed due pre-existing compile error in `test/goals/GoalTreasury.t.sol` (`successRewardsGraceDeadline` missing), unrelated to these additions.
  - Focused suites passed:
    - `forge test --match-path test/flows/FlowAllocationProperties.t.sol`
    - `forge test --match-path test/flows/FlowLedgerChildSyncProperties.t.sol`
    - `forge test --match-path test/goals/BudgetStakeLedgerEconomics.t.sol`

## Open risks

- Property-style tests can become brittle if they overfit to helper implementation details; assertions should stay at external behavior level.

# Budget Ledger Maturation Warmup (Points-Only)

Status: active
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Add anti-snipe maturation to `BudgetStakeLedger` points accrual without changing allocation eligibility/weight semantics. Allocation remains based on raw `allocatedStake`; reward points are based on effective stake that warms up over time.

## Acceptance criteria

- `BudgetStakeLedger` tracks per-user and per-budget warmup debt (`unmaturedStake`) and decays it over time during accrual.
- `registerBudget` caches a maturation window derived from budget `executionDuration` (`M = executionDuration / 10`, min 1s).
- Stake decreases preserve maturity fraction (proportional scaling), preventing maturity concentration exploits.
- Finalization/user preview paths use the same warmup-aware accrual math.
- Tests cover anti-snipe behavior and decrease exploit resistance.
- Existing reward-escrow tests/mocks are updated for new points semantics.
- Required verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - `src/goals/BudgetStakeLedger.sol`
  - reward/ledger tests and local mocks relying on budget checkpoint points
  - architecture/reference docs describing reward points semantics
- Out of scope:
  - `lib/**`
  - changing allocation strategy eligibility semantics (`BudgetStakeStrategy` remains raw stake based)

## Constraints

- Preserve existing external interfaces/events unless strictly necessary.
- Keep settled/finalized cutoff behavior intact (`min(goalFinalizedAt, resolvedAt)`).
- Maintain deterministic checkpoint behavior with sorted/unique recipient IDs.

## Open risks

1. Rounding drift between budget-total points and sum of per-user points due integer math.
   - Mitigation: add tolerance-based invariant tests and keep budget/user formulas symmetric.
2. Test fragility from hardcoded linear stake-time expectations.
   - Mitigation: update mocks with `executionDuration` and revise assertions to warmup-aware expectations.
3. Gas overhead in allocation checkpoint path.
   - Mitigation: keep math O(log dt), avoid loops over users.

## Tasks

1. Implement warmup state, accrual helpers, and checkpoint integration in `BudgetStakeLedger`.
2. Add budget `executionDuration` support in relevant mocks used by ledger/reward tests.
3. Add targeted warmup regression tests (sniping, proportional decrease anti-exploit, budget/user consistency).
4. Update architecture/reference docs for points semantics change.
5. Run required verification suite and record outcomes.

## Decisions

- Warmup is points-only and does not affect `userAllocatedStakeOnBudget`/allocation permissions.
- Maturation period is derived from budget execution duration (`M = executionDuration / 10`, floor with min 1 second).
- For test realism, budget mocks will expose `executionDuration` explicitly.

## Progress log

- 2026-02-20: Read required architecture/reliability/security docs and mapped current ledger + reward test surface.
- 2026-02-20: Plan opened; implementation starting.
- 2026-02-20: Implemented maturation/warmup accounting in `BudgetStakeLedger` with per-user and per-budget unmatured stake tracking and decay math.
- 2026-02-20: Updated reward/ledger mocks to expose `executionDuration()` so tests exercise budget-derived maturation path.
- 2026-02-20: Added warmup regression tests for sniping resistance, anti-concentration on decreases, and budget-vs-user points consistency tolerance.
- 2026-02-20: Updated reward tests to account for warmup rounding semantics.

## Verification

- Required:
  - `forge build -q`
  - `pnpm -s test:lite`
- Optional targeted debug:
  - `forge test --match-path test/goals/RewardEscrow.t.sol -vv`
  - `forge test --match-path test/goals/RewardEscrowIntegration.t.sol -vv`

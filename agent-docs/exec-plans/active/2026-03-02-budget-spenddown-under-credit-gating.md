# 2026-03-02 Budget Spenddown Under Credit Gating

## Goal

Align budget-runtime economics so credit-cap gating remains receive-side while active budgets can still spend down treasury balance, and remove same-cycle ordering lag between gating and budget sync.

## Why

- Current budget target policy is parent-member-rate passthrough only.
- When credit cap disables a budget recipient, parent member rate goes to zero and budget outflow is zeroed on next budget sync, even if treasury balance is non-zero.
- Current `BudgetTCR.syncBudgetTreasuries` order (`treasury.sync()` then credit-cap enforcement) can create one-cycle transition lag.

## Scope

- `src/tcr/BudgetTCR.sol`
- `src/goals/BudgetTreasury.sol`
- `test/BudgetTCRCreditLineGating.t.sol`
- `test/goals/BudgetTreasury.t.sol`
- `test/goals/UnderwritingIntegration.t.sol`
- Architecture/spec docs:
  - `ARCHITECTURE.md`
  - `agent-docs/cobuild-protocol-architecture.md`
  - `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
  - `agent-docs/references/goal-funding-and-reward-map.md`

## Constraints / Invariants

- Keep credit-cap meter receive-side:
  - exposure: `goalFlow.getTotalReceivedByMember(childFlow)`,
  - line: `budgetTotalAllocatedStake * executionDuration / coverageLambda`.
- Preserve trusted-rate boundary:
  - untrusted/third-party net flow spoofing must not directly increase trusted parent-derived component.
- Keep best-effort batch semantics and observability behavior.
- No `lib/**` edits.
- Hard cutover policy (no compatibility shim path).

## Design

1. `BudgetTCR.syncBudgetTreasuries`:
- enforce credit cap first for each active/deployed item,
- then call `treasury.sync()` so target computation observes post-gating parent recipient state in the same cycle.

2. `BudgetTreasury.targetFlowRate` policy:
- active only, timeRemaining > 0 guard remains,
- trusted incoming component from parent member flow (`max(parentRate, 0)`),
- spenddown component from current treasury balance over remaining time (`linear`),
- target = trusted incoming + spenddown, saturated to `int96.max`.

This means:
- if parent inflow is zero (cap-disabled or otherwise), budget can still stream out existing balance linearly to deadline,
- if parent inflow exists, budget streams enough to spend current balance while passing through incoming.

## Verification Plan

- Update/add tests for:
  - cap-disabled recipient still allows budget spenddown from balance after sync,
  - same-cycle coherence when cap flip occurs in `syncBudgetTreasuries`,
  - no regression on trusted parent-rate invariants.
- Run completion workflow passes:
  1. simplify
  2. test-coverage-audit
  3. task-finish-review
- Run required Solidity gate: `pnpm -s verify:required`.

## Risks

- Higher computed target rates may hit buffer caps more often; behavior should remain safe due to `TreasuryFlowRateSync` fallback ladder.
- Existing tests that assert target equals parent incoming may need explicit policy updates.

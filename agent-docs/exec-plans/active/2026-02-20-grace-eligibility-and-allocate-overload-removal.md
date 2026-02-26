# Grace Eligibility + Allocate Overload Removal

Status: completed
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Implement the agreed success-reward semantics and allocation API hardening:
- Remove the 4-arg `CustomFlow.allocate` overload.
- Keep points accrual cutoff at `successAt`.
- Allow budgets that resolve after `successAt` to count as succeeded if they are succeeded by reward-finalization time.
- Harden allocation checkpoint account sourcing to use strategy `accountForAllocationKey` in ledger mode.

## Acceptance criteria

- `CustomFlow` exposes only the 5-arg allocation entrypoint and all call sites compile.
- `BudgetStakeLedger` success classification no longer excludes `resolvedAt > goalFinalizedAt`.
- Points accrual cutoff remains unchanged (`min(goalFinalizedAt, resolvedAt)` behavior).
- Allocate path checkpoints the resolver-derived account in ledger mode.
- Focused tests cover:
  - child-sync skip branches (`TARGET_UNAVAILABLE`, `NO_COMMITMENT`)
  - post-success budget resolution eligibility
  - resolver-derived checkpoint account behavior

## Scope

- In scope:
  - `src/flows/CustomFlow.sol`
  - `src/goals/BudgetStakeLedger.sol`
  - impacted tests/helpers under `test/flows/**` and `test/goals/**`
- Out of scope:
  - reward token/super token deploy-time compatibility checks
  - changes under `lib/**`

## Verification

- Targeted Foundry suites (pass):
  - `forge test --match-path test/flows/FlowBudgetStakeAutoSync.t.sol`
  - `forge test --match-path test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`
  - `forge test --match-path test/flows/FlowAllocationsValidation.t.sol`
  - `forge test --match-path test/flows/FlowAllocationsWitness.t.sol`
  - `forge test --match-path test/flows/FlowAllocationsState.t.sol`
  - `forge test --match-path test/flows/FlowAllocationsMathEdge.t.sol`
  - `forge test --match-path test/flows/FlowAllocationsFuzz.t.sol`
- Repo baseline commands (known unrelated blockers remain):
  - `forge build -q` fails in current tree with Solc internal compiler error (`Tag too large for reserved space`).
  - `pnpm -s test:lite` fails in current tree with the same Solc internal compiler error (`Tag too large for reserved space`).

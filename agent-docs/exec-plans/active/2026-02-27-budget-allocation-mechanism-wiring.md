# Budget Allocation Mechanism Wiring Plan (2026-02-27)

## Goal

Make each accepted budget deployment create its own `AllocationMechanismTCR` instance, while reusing one shared `RoundFactory` deployer across goals. Child budget flows should default `recipientAdmin` to the per-budget mechanism so round recipient lifecycle is localized and curation-driven.

## Scope

- `BudgetTCR` budget stack activation path (`_deployBudgetStack`) and deployment storage.
- `BudgetTCRFactory`/`BudgetTCRDeployer` wiring for shared mechanism dependencies.
- Relevant interfaces for deployer config/getters and arbitrator sink reads.
- Deployment script updates for new shared dependencies.
- Targeted tests covering child-role wiring and mechanism deployment behavior.

## Design

1. Keep goal-level authority unchanged:
- Goal flow `recipientAdmin` remains per-goal `BudgetTCR`.

2. Shared infra, per-budget mechanism:
- `BudgetTCRFactory` holds immutable shared addresses:
  - one `RoundFactory`
  - one `AllocationMechanismTCR` implementation
- `BudgetTCRFactory` initializes each cloned `BudgetTCRDeployer` with those shared addresses plus arbitrator implementation.

3. Budget activation flow:
- `BudgetTCR` prepares stack (`strategy` + `budgetTreasury`).
- `BudgetTCR` clones a per-budget `AllocationMechanismTCR` + per-budget mechanism arbitrator.
- `goalFlow.addFlowRecipient(...)` uses:
  - `recipientAdmin = allocationMechanism`
  - `flowOperator = budgetTreasury`
  - `sweeper = budgetTreasury`
- Deploy/initialize `BudgetTreasury` as today.
- Initialize `AllocationMechanismTCR` against that budget treasury/flow with defaults derived from current budget TCR config and arbitrator params.

4. Keep config surface minimal:
- Reuse existing `BudgetTCR` governance/deposit/meta-evidence settings for mechanism registry and round defaults.
- Reuse arbitrator params from `arbitrator.getArbitratorParamsForFactory()`.

## Invariants

- `BudgetTCR` remains sole goal-flow recipient lifecycle admin.
- Budget-flow rate authority remains treasury-owned (`flowOperator = budgetTreasury`).
- Mechanism initialize must preserve strict recipient-admin check on budget flow.
- No `lib/**` changes.

## Verification

- `pnpm -s verify:required`
- Completion workflow subagent passes:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`
- Re-run `pnpm -s verify:required` after simplify/coverage changes.

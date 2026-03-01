# Exec Plan: Budget TCR Authority + One-Stake Budget Allocation

Date: 2026-02-19
Owner: Codex
Status: Completed

## Goal
Refactor Budget TCR runtime authority to match the FlowTCR pattern (TCR directly manages parent-flow recipient mutations) and enable one-stake UX by deriving budget-internal allocation weight from `BudgetStakeLedger` checkpoints.

## Scope
- Move runtime goal-flow add/remove recipient operations from `BudgetTCRDeployer` into `BudgetTCR`.
- Keep deployer/builder responsibilities mechanical (deploy stack components and return addresses).
- Add budget-stake-ledger-backed weight reads for per-user/per-budget allocation weight.
- Introduce a budget allocation strategy that reads per-budget stake from the ledger.
- Wire Budget TCR child-flow deployment to use the stake-ledger-backed strategy.
- Update interfaces/tests/docs for new authority and allocation model.

## Decisions
- Preserve current budget stack shape where possible for compatibility; prioritize authority and allocation source changes first.
- Use `BudgetStakeLedger` checkpoints from goal-flow allocation updates as source of truth for per-budget stake.
- Keep validation and factory role boundaries explicit while removing runtime privileged dependence on deployer.

## Risks
- Access-control regressions around parent-flow recipient add/remove.
- Recipient-shape mismatch (child-flow recipient vs budget treasury identity) for budget stake tracking.
- Strategy weight/source mismatches causing allocation reverts or zero-weight allocations.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

## Outcome
- `BudgetTCR` now owns runtime goal-flow recipient add/remove authority (goal-flow manager expected to be `BudgetTCR`).
- `BudgetTCRDeployer` is mechanical only (`prepareBudgetStack`, `deployBudgetTreasury`).
- Budget child flows use `BudgetStakeStrategy` and derive allocator weight from `BudgetStakeLedger` budget stake checkpoints.
- `RewardEscrow` budget tracking supports both direct budget recipients and child-flow recipients via flow manager.

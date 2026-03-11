# Exec Plan: Budget TCR V1

Date: 2026-02-19
Owner: Codex
Status: Completed

## Goal
Add a per-goal Budget TCR built on `GeneralizedTCR` that can curate and auto-deploy budget child stacks under a goal flow, with manager-authorized flow-rate control for `BudgetTreasury` and onchain payload bounds validation.

## Scope
- Add concrete `BudgetTCR` + interface + storage + helper libraries.
- Add a deployable per-goal stack factory.
- Add a mintable votes/deposit token for arbitrator/TCR economics.
- Update flow authorization to allow manager to call `setFlowRate`.
- Add targeted tests for Budget TCR lifecycle and manager flow-rate authorization.
- Update architecture docs to include Budget TCR domain wiring.

## Decisions
- Omit `deploymentOf` public getter.
- Use helper-contract + library pattern (`BudgetTCRDeployer`, `BudgetTCRValidator`, `BudgetTCRDeployments`) to keep `BudgetTCR` runtime under EIP-170.
- Split token/deployer/validator constructor deployment into helper factories (`BudgetTCRTokenFactory`, `BudgetTCROpsFactory`) so `BudgetTCRFactory` runtime stays under EIP-170.
- One Budget TCR stack per goal.
- Auto-deploy child flow + budget treasury + budget-specific stake vault/strategy on accepted listing.
- On removal, delist from parent flow and attempt `resolveFailure` on deployed budget treasury.
- Oracle fields are validated/stored-only in v1 (no runtime oracle wiring).
- Goal-flow manager for budget add/remove operations is the per-goal `BudgetTCRDeployer` (`onlyBudgetTCR` gated), not `BudgetTCR` directly.

## Risks
- Cross-contract lifecycle coupling on remove/finalize.
- Initialization/order constraints across arbitrator, TCR, and per-budget deployment path.
- Flow access-control change could regress existing role assumptions.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

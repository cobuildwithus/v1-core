# Exec Plan: BudgetTCR Non-Upgradeable + BudgetTreasury Controller Auth

Date: 2026-02-21
Owner: Codex
Status: In Progress

## Goal
Remove privileged upgrade and ownership surfaces in the budget stack by:
- making BudgetTreasury controller-gated (no Ownable inheritance), and
- deploying BudgetTCR as a non-upgradeable instance (no ERC1967 proxy path for BudgetTCR).

## Scope
- `src/goals/BudgetTreasury.sol` and `src/interfaces/IBudgetTreasury.sol`
- `src/goals/GoalStakeVault.sol` authorization fallback path for forwarded treasuries
- `src/tcr/BudgetTCRFactory.sol` deployment model for BudgetTCR
- `src/tcr/BudgetTCR.sol` constructor/initializer behavior required for non-proxy deployment
- impacted tests under `test/goals/**`, `test/BudgetTCR*.t.sol`, and related helpers
- architecture/security docs that describe authority and upgrade boundaries

## Constraints
- Do not modify anything under `lib/**`.
- Leave unrelated pre-existing working tree changes untouched.
- Preserve existing lifecycle/terminalization invariants for budget removal and finalization.
- Keep trusted-core fail-closed behavior for authority resolution.

## Acceptance criteria
- BudgetTreasury no longer inherits Ownable and no longer exposes ownership transfer/renounce surfaces.
- BudgetTreasury privileged methods are callable only by an immutable controller address.
- GoalStakeVault treasury authorization remains functional for both Ownable treasuries and controller-based budget treasuries.
- BudgetTCR deployment path in factory no longer uses ERC1967 proxy for BudgetTCR.
- `forge build -q` passes.
- `pnpm -s test:lite` passes.

## Progress log
- 2026-02-21: Audited current authority/deployment call graph and identified GoalStakeVault `owner()` coupling that must be adapted for controller-based treasuries.
- 2026-02-21: Established implementation plan and validation sequence.

## Open risks
- Hidden assumptions in tests/docs that BudgetTreasury is Ownable.
- Any external scripts expecting prior BudgetTCRFactory constructor/update-implementation API.
- Auth regressions around `setJurorSlasher` when treasury is forwarded before concrete budget treasury deployment.

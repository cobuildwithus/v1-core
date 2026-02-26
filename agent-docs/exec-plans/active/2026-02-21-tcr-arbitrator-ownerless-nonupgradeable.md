# Exec Plan: TCR + Arbitrator Ownerless/Non-Upgradeable

Date: 2026-02-21
Owner: Codex
Status: Completed (with repo-level verification blockers)

## Goal
Remove ownership and upgrade authorization surfaces from:
- `GeneralizedTCR` / `BudgetTCR`
- `ERC20VotesArbitrator`

while preserving the existing governor-driven TCR parameter controls.

## Scope
- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `src/tcr/BudgetTCRFactory.sol`
- impacted interfaces (`src/tcr/interfaces/**`) and TCR config structs
- impacted tests under `test/**` that assume owner/upgrade APIs
- docs that describe TCR/arbitrator governance and upgrade model

## Constraints
- Do not modify `lib/**`.
- Keep `GeneralizedTCR` governor controls for now.
- Replace invalid-round owner withdrawal path with explicit sink behavior.
- Keep deployment flow deterministic and avoid adding CREATE2/address prediction complexity.

## Acceptance criteria
- `GeneralizedTCR` no longer inherits Ownable/UUPS and no longer exposes upgrade auth.
- `ERC20VotesArbitrator` no longer inherits Ownable/UUPS and no longer exposes owner-gated mutators.
- Invalid-round reward withdrawal routes to a configured sink (no owner capture path).
- Factory deploys an arbitrator instance without upgrade proxy control.
- Interfaces/tests/docs reflect the new authority model.
- `forge build -q` and `pnpm -s test:lite` executed and results reported.

## Open risks
- Existing tests currently fail for unrelated compile drift; this may mask new regressions.
- External integrations may assume prior factory/arbitrator initializer signatures.
- Removing arbitrator owner-setters hardens trust but removes runtime parameter tuning.

## Verification outcomes (2026-02-21)
- `forge build -q`: fails in unrelated goal treasury interface merge (`BudgetTreasury` / `GoalTreasury` missing UMA assertion method overrides), outside TCR/arbitrator scope.
- `pnpm -s test:lite`: fails with same unrelated compile blocker.
- Targeted suites executed for changed surface:
  - `forge test --match-path test/ERC20VotesArbitratorInitConfigUpgrade.t.sol` ✅ (8/8)
  - `forge test --match-path test/ERC20VotesArbitratorStakeVaultMode.t.sol` ✅ (11/11)
  - `FOUNDRY_JOBS=2 forge test --match-path test/GeneralizedTCRGovernanceUpgrade.t.sol` ✅ (12/12)

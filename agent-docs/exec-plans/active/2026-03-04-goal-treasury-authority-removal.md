# 2026-03-04 GoalTreasury Authority Removal (Safe Cutover)

## Goal

Remove GoalTreasury authority indirection used for StakeVault slasher wiring, and hard-wire both slashers during GoalTreasury initialization.

## Scope

- Remove GoalTreasury authority storage/surface and config forwarding functions.
- Remove StakeVault callback to `goalTreasury.authority()`.
- Extend goal initialization config to include predeployed juror + underwriter slasher addresses.
- Move router deployment/wiring to core stack initialization.
- Update BudgetTCRFactory to strictly validate preconfigured slashers and authorize the deployed arbitrator on the preconfigured juror router.
- Update affected tests/fixtures/docs.

## Non-Goals

- Do not remove `BudgetTreasury.controller`/`authority`.
- Do not change JurorSlasherRouter authority ownership model in this cutover (keep `BudgetTCRFactory` authority for low-risk compatibility).

## Invariants To Preserve

- StakeVault slasher setters remain one-time and contract-code-only.
- BudgetTCR stack deploy still authorizes its arbitrator to slash jurors.
- Underwriter slasher router authority must still match predicted BudgetTCR.
- No behavior change to budget manual failure/controller semantics.

## Planned Changes

1. Interface + contract surface cleanup:
   - `IGoalTreasury`: remove authority/configure slasher surface; add slasher fields in `GoalConfig`.
   - `GoalTreasury`: set stake-vault slashers in `initialize`; remove authority members/functions.
   - `IStakeVault` + `StakeVault`: remove treasury-authority callback error/helper; allow only `goalTreasury` caller for slasher setters.
2. Deployment/wiring:
   - `GoalFactoryCoreStackDeploy`: deploy `JurorSlasherRouter` + clone/init `UnderwriterSlasherRouter`; pass into goal config and initialize treasury.
   - `GoalFactory`: pass underwriter-router implementation into core-stack init and consume returned router for BudgetTCR deploy config.
3. BudgetTCRFactory:
   - Stop trying to configure slashers via GoalTreasury.
   - Require preconfigured juror/underwriter slashers on StakeVault and validate strict compatibility.
4. Tests and docs:
   - Update factory/treasury/stakevault tests to new authority model.
   - Update all goal config fixtures for new slasher fields.
   - Update architecture docs references where they still mention treasury authority callback.

## Verification

- `pnpm -s verify:required`
- Completion workflow passes after implementation:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

# 2026-03-04 Factory Discovery Cutover

## Goal

Route deploy-time discovery for budget child stack and allocation mechanism addresses through fixed factory emitters, and expose goal allocation pipeline in `GoalFactory` deployment outputs/events.

## Scope

- Add factory callback discovery events and authenticated callback entrypoints.
- Wire `BudgetTCR` stack actions -> stack deployer -> factory callback path.
- Keep existing `BudgetTCR` events additive (no removals) for compatibility.
- Add goal allocation pipeline address to `GoalFactory.DeployedGoalStack`.
- Update Solidity tests/mocks/scripts impacted by interface/signature changes.
- Update architecture/spec docs for new discovery surface.

## Non-Goals

- No indexer changes in this repo.
- No lifecycle or funds-routing semantic changes.
- No removal of current `BudgetTCR` event surfaces.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow: simplify -> test-coverage-audit -> task-finish-review.

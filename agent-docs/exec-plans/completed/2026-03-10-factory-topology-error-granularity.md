# Factory And Topology Error Granularity

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Replace coarse factory/topology revert surfaces with probe-specific custom error payloads so failed deployments and budget registrations identify the failing phase without behavior changes.

## Scope

- `src/rounds/RoundFactory.sol`
- `src/teamflow/TeamFlowFactory.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/interfaces/IBudgetStakeLedger.sol`
- Focused regression tests for the affected revert paths

## Out Of Scope

- Budget delta preview/checkpoint behavior changes in `BudgetStakeLedger`
- Treasury lifecycle or deployment wiring changes beyond revert detail
- Non-targeted docs updates unless implementation fallout requires them

## Constraints

- Do not touch `lib/**`.
- Preserve validation semantics and ordering unless a reorder is required to expose the failing probe deterministically.
- Treat the custom error ABI changes as intentional integrator-facing changes and keep payloads minimal but specific.
- Avoid overlap with the active `RoundFactory` refactor claim and the in-flight `BudgetStakeLedger` delta-preview work.

## Planned Work

1. Add probe-specific error payloads in `RoundFactory` and `TeamFlowFactory` for dependency reads and invalid resolved addresses.
2. Refine `IBudgetStakeLedger.INVALID_BUDGET_TOPOLOGY` to include topology probe context and update `BudgetStakeLedger` registration validation to use it.
3. Update focused tests to assert the new probe context and cover the newly separated failure points.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Status

- Implemented probe-specific error payloads in the scoped factory/topology files and updated focused regression tests.
- Focused suites passed:
  - `forge test --match-path test/rounds/RoundFactory.t.sol`
  - `forge test --match-path test/teamflow/TeamFlowFactory.t.sol`
  - `forge test --match-path test/goals/BudgetStakeLedgerCoverageCutover.t.sol`
- Simplify pass completed with no code changes.
- Coverage/review subagent attempts stalled; completed those audits in the parent agent instead.
- Final repo-wide verification passed after shared-worktree cleanup via `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

# Goal

Add a `TeamFlow` allocation mechanism family and make each new per-budget `AllocationMechanismTCR` start with both `RoundFactory` and `TeamFlowFactory` allowlisted so TeamFlow is immediately available as a curated mechanism type without moving seat logic into treasuries.

Runtime topology note: the original manager-plus-child-`CustomFlow` shape described in this plan was later superseded by `agent-docs/exec-plans/active/2026-03-10-teamflow-flow-runtime-refactor.md`; `TeamFlowFactory` now deploys a single `TeamFlow` payout runtime and returns it as both `mechanism` and `payoutRecipient`.

# Scope

- `src/tcr/AllocationMechanismTCR.sol`
- `src/tcr/interfaces/IBudgetTCR.sol`
- `src/tcr/interfaces/IBudgetTCRStackDeployer.sol`
- `src/tcr/BudgetTCRDeployer.sol`
- `src/tcr/BudgetTCRFactory.sol`
- `src/tcr/library/BudgetTCRStackActions.sol`
- `script/DeployGoalFactoryImplementations.s.sol`
- New `src/teamflow/**`
- Targeted tests under `test/rounds/**`
- Targeted tests under `test/BudgetTCR*.t.sol`
- New `test/teamflow/**`
- Matching docs in `agent-docs/**`

# Constraints

- Preserve the existing escrow-funded mechanism flow in `AllocationMechanismTCR`.
- TeamFlow must be an additional possible mechanism factory, not an auto-created mechanism listing or auto-activated mechanism instance.
- Keep `RoundFactory` available on the same budgets after the change.
- Use hard removal for TeamFlow seats (`removeRecipient`), not enable/disable.
- Avoid unrelated spend-policy changes on files currently touched by the active spend-cutover task.

# Acceptance Criteria

- `AllocationMechanismTCR` accepts multiple initial allowlisted factories at init.
- Budget stack deployment initializes each per-budget mechanism registry with both `RoundFactory` and `TeamFlowFactory` allowlisted.
- Discovery/events surface the configured initial factories.
- `TeamFlowFactory` deploys a `TeamFlow` manager plus child `CustomFlow`, and returns the child flow as payout recipient.
- `TeamFlow` manages equal-split seat payouts, recalculates target outflow from `perSeatRate` and `maxTotalRate`, and hard-removes departed seats from the child flow.
- Targeted tests cover multi-factory allowlisting and TeamFlow deployment/roster behavior.

# Open Questions

- None currently. Assumed v1 remains escrow-release-driven and does not add a direct-streaming mechanism callback path.

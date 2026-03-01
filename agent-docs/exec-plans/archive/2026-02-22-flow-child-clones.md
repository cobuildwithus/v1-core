# Flow Child Runtime Clone Deployment

Status: active
Created: 2026-02-22
Updated: 2026-02-22

## Goal

Remove ERC1967 proxy deployment for child flow recipients and use minimal clone deployment (EIP-1167) to match non-upgradeable runtime intent with lower complexity and clearer architecture.

## Scope

- In scope:
  - `src/library/CustomFlowLibrary.sol` child flow deployment path.
  - Flow tests that rely on child deployment shape/behavior.
  - Architecture/security docs describing flow runtime deployment.
- Out of scope:
  - Changes under `lib/**`.
  - Reintroducing runtime upgradeability for flow contracts.
  - Broad test-harness migration for root flow fixture deployments unless required by this change.

## Constraints

- Keep child-flow initialization and manager/parent wiring behavior unchanged.
- Keep `Flow` runtime non-upgradeable semantics unchanged.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress Log

- 2026-02-22: Created plan and started implementation/design impact pass.
- 2026-02-22: Switched `CustomFlowLibrary.deployFlowRecipient` from `ERC1967Proxy` deployment to `Clones.clone` and added explicit `flowImpl.code.length` guard.
- 2026-02-22: Added regression coverage in `test/flows/FlowRecipients.t.sol` to assert child recipient runtime bytecode matches EIP-1167 clone shape.
- 2026-02-22: Updated architecture/security docs to reflect non-upgradeable flow runtimes with clone-based child deployments.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (fails in pre-existing dirty-tree suites)
  - failing suites observed: `test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`,
    `test/flows/FlowBudgetStakeAutoSync.t.sol`, `test/flows/FlowChildSyncBehavior.t.sol`,
    `test/goals/GoalStakeVault.t.sol`
  - changed-surface suite `test/flows/FlowRecipients.t.sol` passes, including new clone regression test.

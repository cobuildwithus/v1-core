# Flow Upgrade Entrypoint Surface Removal

Status: active
Created: 2026-02-22
Updated: 2026-02-22

## Goal

Remove the Flow runtime `upgradeToAndCall` compatibility stub and associated `IFlow` surface so Flow contracts expose no upgrade selector at all.

## Scope

- In scope:
  - `src/interfaces/IFlow.sol` (`NON_UPGRADEABLE` error + `upgradeToAndCall` declaration).
  - `src/Flow.sol` (`upgradeToAndCall` implementation stub).
  - Flow upgrade-surface tests in `test/flows/FlowUpgrades.t.sol`.
  - Architecture/security docs that currently describe the reverting entrypoint.
- Out of scope:
  - TCR/arbitrator non-upgradeable stubs.
  - Changes under `lib/**`.

## Constraints

- Keep Flow runtime non-upgradeable.
- Preserve all existing manager/parent authority behavior.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress Log

- 2026-02-22: Created plan and started Flow upgrade-surface removal pass.
- 2026-02-22: Removed `NON_UPGRADEABLE` + `upgradeToAndCall` from `IFlow`, and removed `Flow.upgradeToAndCall` implementation.
- 2026-02-22: Updated `test/flows/FlowUpgrades.t.sol` to assert missing selector surface (`upgradeToAndCall`/`upgradeAllChildFlows`).
- 2026-02-22: Removed unreachable post-`Clones.clone` zero-address check in `CustomFlowLibrary` during cleanup pass.
- 2026-02-22: Updated architecture/security docs to describe non-upgradeable Flow runtime surface as “no upgrade selector exposed.”

## Verification

- `forge build -q` (pass)
- `forge test -q --match-path test/flows/FlowUpgrades.t.sol` (pass)
- `forge test -q --match-path test/flows/FlowRecipients.t.sol` (pass)
- `pnpm -s test:lite` (fails in pre-existing dirty-tree suites; changed-surface suites pass)
  - failing suites observed: `test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`,
    `test/flows/FlowChildSyncBehavior.t.sol`

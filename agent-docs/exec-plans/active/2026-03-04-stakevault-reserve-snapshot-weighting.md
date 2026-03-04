# StakeVault Reserve Snapshot Weighting

Status: active
Created: 2026-03-04
Updated: 2026-03-04

## Goal

Adjust goal-token stake weighting so issuance pricing remains permanently weighted by a snapshot of
ruleset weight, while a reserve-percent premium (also snapshotted) decays linearly from activation
to deadline.

## Scope

- `src/goals/StakeVault.sol`
- `src/interfaces/IStakeVault.sol`
- `test/goals/StakeVault.t.sol`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/references/goal-funding-and-reward-map.md`

## Constraints

- Preserve live staking-open gate (`currentOf(goalRevnetId).weight > 0`).
- Preserve COBUILD 1:1 weight behavior.
- Keep deposit-time accounting model (no continuous global reweighting sync).
- Revert when snapshotted reserved percent is 100%.
- Do not modify `lib/**`.

## Acceptance Criteria

- StakeVault snapshots goal ruleset weight and reserved percent once at initialization.
- Goal stake weight formula always includes issuance pricing from snapshot weight.
- Reserve premium decays linearly from full at activation/pre-activation to zero at deadline.
- Deadline endpoint equals issuance-priced weight (not raw goal amount).
- Tests cover reserve decay, snapshot invariance, and invalid 100% reserved snapshot config.

## Verification

- Required gate: `pnpm -s verify:required`
- Required gate: `pnpm -s lint:solidity:warnings`

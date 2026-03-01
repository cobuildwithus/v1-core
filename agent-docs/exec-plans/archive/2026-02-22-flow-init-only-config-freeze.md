# Flow Init-Only Config Freeze

Status: active
Created: 2026-02-22
Updated: 2026-02-22

## Goal

Reduce privileged runtime surface on `Flow` by freezing post-init mutation for deployment-time configuration knobs:
- `setFlowImpl`
- `setConnectPoolAdmin`
- `setDefaultBufferMultiplier`
- `setManagerRewardFlowRatePercent`

## Scope

- In scope:
  - Remove the four setter entrypoints from the runtime flow surface.
  - Update flow and integration tests to assert freeze behavior and move behavior coverage to init-time configuration.
  - Update architecture/spec docs to record these knobs as init-only.
- Out of scope:
  - `lib/**` changes.
  - Freezing other mutable flow knobs (`manager`, `managerRewardPool`, `allocationLedger`, `allocationHook`, child sync mode).

## Constraints

- Preserve existing runtime behavior for mutable flow controls.
- Required verification:
  - `forge build -q`
  - `pnpm -s test:lite`

## Progress Log

- 2026-02-22: Removed all four targeted setter entrypoints from `src/Flow.sol`.
- 2026-02-22: Updated flow tests to assert removed selector behavior and replaced runtime percentage/buffer mutation cases with init-time deployment variants.
- 2026-02-22: Updated reward-escrow integration fixture wiring to avoid post-init reward-percent mutation.

## Verification

- `forge build -q` (pass)
- `pnpm -s test:lite` (fails in pre-existing branch state)
  - observed failures are outside the removed-setter surface and are currently:
    - `test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`
    - `test/flows/FlowChildSyncBehavior.t.sol` (14 failures)
- Flow-focused targeted checks for this change passed:
  - `forge test --match-path test/flows/FlowRates.t.sol`
  - `forge test --match-path test/flows/FlowInitializationAndAccessSetters.t.sol`
  - `forge test --match-path test/flows/FlowInitializationAndAccessAccess.t.sol`
  - `forge test --match-path test/flows/FlowInitializationAndAccessInit.t.sol`

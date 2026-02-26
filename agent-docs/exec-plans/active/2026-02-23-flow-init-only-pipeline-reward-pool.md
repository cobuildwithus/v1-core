# Flow Init-Only Pipeline + Manager Reward Pool Freeze

Status: active
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Reduce privileged runtime surface in `Flow` by making allocation-pipeline and manager-reward-pool configuration init-only.

## Scope

- In scope:
  - Move allocation pipeline selection to initialization config.
  - Remove runtime mutators:
    - `setAllocationPipeline`
    - `setManagerRewardPool`
  - Update interfaces, initialization wiring, and tests/deployment fixtures.
  - Update architecture/spec docs to reflect init-only behavior.
- Out of scope:
  - `lib/**` changes.
  - Changing `sweepSuperToken` auth model.

## Constraints

- Preserve existing allocation/child-sync invariants and ledger validation semantics.
- Preserve manager/parent sweep behavior and treasury residual-settlement flows.
- Required verification:
  - `pnpm -s verify:required`

## Progress Log

- 2026-02-23: Added init-time `allocationPipeline` field in flow init config and initialization validation path.
- 2026-02-23: Removed runtime `setAllocationPipeline` and `setManagerRewardPool` entrypoints from Flow surface/interfaces.
- 2026-02-23: Updated flow/goals tests and fixtures to configure pipeline/reward-pool at deployment time.
- 2026-02-23: Reworked ledger-pipeline tests to validate init-time wiring and removed runtime setter dependencies.

## Verification

- Pending

## Open Risks

- Integrations that previously rotated manager reward pool or swapped allocation pipeline at runtime will require redeploy/reinit workflows.

# Agent 4 Underwriting Cap + Goal Config Plumbing

Status: completed
Created: 2026-03-01
Updated: 2026-03-01

## Goal

Implement Agent 4 vNext underwriting scope: add goal-level underwriting config fields (`coverageLambda`, `budgetPremiumPpm`, `budgetSlashPpm`), expose treasury getters/configuration surfaces, and enforce insured-cap clamping in goal flow-rate sync.

## Acceptance criteria

- `IGoalTreasury.GoalConfig` includes `coverageLambda`, `budgetPremiumPpm`, `budgetSlashPpm`.
- `GoalTreasury` stores/exposes the new config fields.
- `GoalTreasury.sync()` target-rate path clamps spend target by insured capacity cap `totalUnits / coverageLambda` when `coverageLambda > 0`.
- `IGoalTreasury` + `GoalTreasury` include `configureUnderwriterSlasher(address)` and corresponding event/error/access controls mirroring existing treasury slasher config style.
- Goal deployment plumbing (`GoalFactory` + core stack deploy libs) passes the new config fields correctly.
- Tests cover insured-cap clamp behavior and new config surfaces.
- Required Solidity gate passes: `pnpm -s verify:required`.

## Scope

- In scope:
  - `src/interfaces/IGoalTreasury.sol`
  - `src/goals/GoalTreasury.sol`
  - `src/goals/GoalFactory.sol`
  - `src/goals/library/GoalFactoryCoreStackDeploy.sol`
  - helper deploy libs touched by GoalConfig init ordering
  - goal treasury/factory tests needed for coverage
- Out of scope:
  - `lib/**`
  - PremiumEscrow implementation details
  - StakeVault internal slashing math (owned by another stream)
  - child-flow manager reward ppm plumbing (owned by another stream)

## Decisions

- Hard cutover semantics: new goal config fields are first-class and required in stack deployment paths.
- Insured-cap clamp is applied at goal sync target calculation boundary (before treasury flow-rate apply helper call).
- `coverageLambda == 0` means "no underwriting cap" (existing spend target behavior preserved).

## Progress log

- 2026-03-01: Claimed scope in `COORDINATION_LEDGER` and reviewed required architecture/spec/security/runtime docs.
- 2026-03-01: Implemented `IGoalTreasury` + `GoalTreasury` underwriting config fields/getters and insured-cap clamp (`totalUnits / coverageLambda`) in target flow-rate sync/read path.
- 2026-03-01: Added `configureUnderwriterSlasher(address)` treasury surface and `IStakeVaultUnderwriterConfig` typed interface bridge.
- 2026-03-01: Plumbed underwriting config through `GoalFactory` and `GoalFactoryCoreStackDeploy`; updated factory deploy script params/env parsing.
- 2026-03-01: Updated goal/factory fixture tests and treasury shared mocks; added cap-edge regression coverage.
- 2026-03-01: Ran completion workflow passes (`simplify` -> `test-coverage-audit` -> `task-finish-review`).
- 2026-03-01: Ran required gate `pnpm -s verify:required` (fails due unrelated in-flight suites outside Agent-4 scope; see handoff for exact failing suites).

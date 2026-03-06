# Completion Note

- Completed: 2026-03-06
- Resulting PR(s): none
- Follow-up items: consider adding a `GoalFactory` end-to-end regression for mixed explicit/default budget TCR policy wiring.

# Exec Plan: TCR Shared Config Canonicalization

Date: 2026-03-06
Owner: Codex
Status: Completed

## Goal
Replace the repeated near-identical TCR registry config structs with one canonical shared `GeneralizedTCR` config shape, and remove the long positional base initializer call from concrete TCRs.

## Scope
- `src/tcr/interfaces/IGeneralizedTCRConfig.sol`
- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/AllocationMechanismTCR.sol`
- `src/tcr/RoundSubmissionTCR.sol`
- `src/tcr/interfaces/IBudgetTCR.sol`
- `src/tcr/BudgetTCR.sol`
- `src/tcr/BudgetTCRFactory.sol`
- `src/tcr/library/BudgetTCRStackActions.sol`
- `src/rounds/RoundFactory.sol`
- `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`
- `src/goals/GoalFactory.sol`
- affected round/budget/goal factory tests
- `agent-docs/references/tcr-and-arbitration-map.md`

## Constraints
- Preserve TCR lifecycle and deposit-routing behavior exactly.
- Keep storage layout unchanged.
- Keep factory-derived config fields explicit where they are semantically derived rather than user-specified.
- Do not overwrite in-flight topology-registry edits in shared `BudgetTCR` files.

## Acceptance Criteria
- Concrete TCRs initialize `GeneralizedTCR` through a shared config struct rather than positional arguments.
- Shared config fields are defined once canonically and embedded by concrete TCR-specific config wrappers.
- Budget and round deployment paths continue to derive and pass the correct arbitrator/token/deposit-strategy dependencies.
- Required Solidity verification passes.

## Progress Log
- 2026-03-06: Claimed scope in coordination ledger and opened plan.
- 2026-03-06: Added `src/tcr/interfaces/IGeneralizedTCRConfig.sol` as the canonical shared registry policy/config type surface.
- 2026-03-06: Refactored `GeneralizedTCR` to consume the shared config struct instead of the positional 11-argument initializer.
- 2026-03-06: Updated `BudgetTCR`, `AllocationMechanismTCR`, `RoundSubmissionTCR`, `BudgetTCRFactory`, `BudgetTCRStackActions`, `RoundFactory`, `GoalFactoryBudgetTcrDeploy`, and `GoalFactory` to compose the shared config through their local init/deployment shapes.
- 2026-03-06: Updated affected round/budget/goal-factory tests and TCR docs to follow the shared config and policy split.
- 2026-03-06: `forge build -q --skip test/**` passed.
- 2026-03-06: Full `forge build -q` passed after fixture updates.
- 2026-03-06: Simplified `BudgetTCRFactory` policy normalization and `GoalFactoryBudgetTcrDeploy.resolveRegistryConfig` to remove redundant tuple/default plumbing.
- 2026-03-06: `forge test --match-path test/goals/GoalFactoryBudgetTcrDeploy.t.sol -q` passed after the simplification pass.
- 2026-03-06: `pnpm -s verify:required` passed on the final tree.
- 2026-03-06: `pnpm -s lint:solidity:warnings` matched the warnings baseline.

## Open Risks
- `IBudgetTCR` and `BudgetTCRStackActions` are concurrently edited, so config-type changes must be tightly scoped to avoid merge-like conflicts.
- Test fixtures encode the old struct shapes in several places; compile fallout will be broad until all call sites are updated together.

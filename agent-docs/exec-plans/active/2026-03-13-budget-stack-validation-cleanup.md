# Budget Stack Validation Cleanup

Status: completed
Created: 2026-03-13
Updated: 2026-03-13

## Goal

Close the remaining managed/open budget-stack validation gaps so controller initialization, prepared stack consumption, and no-risk treasury instantiation each fail closed with explicit, capability-shaped semantics.

## Scope

- In scope:
  - move managed success-assertion liveness validation into `ManagedBudgetController.initialize(...)`
  - add explicit prepared-stack shape validation for managed and open stack consumers
  - remove the managed controller's exact child-strategy-factory init pin and validate deployer traits instead
  - remove the no-risk placeholder `RiskModuleInitConfig` path from `BudgetStackInstantiationLib`
  - align zero-bond semantics across managed/open surfaces
  - add/update focused tests and refresh touched architecture/plan docs
- Out of scope:
  - changing budget economics beyond the zero-bond rule needed for consistency
  - redesigning the shared stack deployer ABI beyond this validation cleanup
  - editing immutable completed/archive execution plans

## Constraints

- Preserve the shared budget-stack substrate and existing managed/open preset split.
- Keep trusted-core deployment paths fail-fast on required capability mismatches.
- Do not reintroduce dummy premium/risk modules or compatibility shims.
- Keep tree-compiling changes in one pass and run the required Solidity verification, size check, and completion workflow before handoff.

## Acceptance Criteria

- Standalone managed controller initialization rejects zero `successAssertionLiveness`.
- Managed/open budget creation reverts when the prepared stack shape disagrees with the expected preset semantics.
- Managed controller validation relies on preset traits, not an extra exact child-strategy-factory init pin, if that coupling is removed.
- No-risk budget stack instantiation no longer routes through a dummy risk-module config.
- Open and managed paths use the same zero-bond rule.
- Regressions cover the new fail-closed validation paths.

## Progress Log

- 2026-03-13: Plan created and coordination ledger ownership recorded.
- 2026-03-13: Removed `budgetChildStrategyFactory` from `ManagedBudgetController.InitConfig`, moved managed liveness validation into controller initialization, added explicit prepared-stack shape checks for managed/open consumers, split the no-risk instantiation helper path, relaxed open zero-bond validation to match managed semantics, and refreshed matching docs/active plan references.
- 2026-03-13: Completion workflow finished cleanly after simplify and coverage subagent passes; `pnpm -s verify:required`, `pnpm -s lint:solidity:warnings`, `pnpm -s build:sizes`, and the follow-up managed-stack regression lane all passed.

## Open Risks

- Removing `budgetChildStrategyFactory` from the managed controller init surface is an interface change and must update all call sites in one pass.
- Prepared-stack validation must remain consistent with deployer runtime behavior or valid deployments will fail closed.

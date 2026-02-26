# Exec Plan: Remove Remaining Centralization Surfaces (Factory + GoalTreasury + Flow)

Date: 2026-02-21
Owner: Codex
Status: In Progress

## Goal
Implement user-requested hardening:
- remove `Ownable` from `BudgetTCRFactory`
- make `GoalTreasury.resolveFailure` permissionless
- make `GoalTreasury.cobuildRevnetId` immutable at deploy-time
- remove `Flow`/`CustomFlow` UUPS + Ownable authority paths

## Scope
- `src/tcr/BudgetTCRFactory.sol`
- `src/goals/GoalTreasury.sol`
- `src/interfaces/IGoalTreasury.sol`
- `src/Flow.sol`
- `src/flows/CustomFlow.sol`
- `src/library/FlowInitialization.sol`
- `src/interfaces/IFlow.sol`
- targeted tests/docs impacted by API/authority changes

## Constraints
- Do not modify `lib/**`.
- Preserve deterministic deployment and current flow wiring semantics where possible.
- Keep compatibility stubs where useful to avoid broad compile churn (`upgradeToAndCall`, ownership APIs) while disabling privilege.

## Acceptance criteria
- `BudgetTCRFactory` has no owner role.
- `GoalTreasury.resolveFailure` callable by anyone (state-gated only).
- `cobuildRevnetId` is immutable and no mutable admin path remains.
- `Flow` no longer inherits UUPS/Ownable and has no effective owner upgrade/admin authority.
- Child flow deployment still works and existing integration interfaces remain coherent.
- Required verification commands executed and results reported.

## Open risks
- Existing repo compile drift may still block full-suite verification.
- Flow ownership/upgrades are referenced heavily in tests; behavior-facing tests will need adaptation.
- Compatibility stubs reduce churn but may conceal stale assumptions in downstream callers.

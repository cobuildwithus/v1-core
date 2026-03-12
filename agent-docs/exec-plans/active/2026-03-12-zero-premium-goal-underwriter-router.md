# Zero-Premium Goal Underwriter Router

Status: in_progress
Created: 2026-03-12
Updated: 2026-03-12

## Goal

Remove the goal-level `UnderwriterSlasherRouter` from canonical zero-premium (`budgetPremiumPpm == 0 && budgetSlashPpm == 0`) goal deployments, while preserving the existing premium-enabled deployment and slashing paths.

## Scope

- In scope:
  - Make goal deployment skip cloning/configuring the underwriter router for canonical `0/0` goals.
  - Allow `GoalTreasury` initialization to omit `underwriterSlasher` only in that canonical `0/0` lane.
  - Add focused regressions for zero-premium and premium-enabled deployments.
  - Update durable architecture/spec docs for the new deployment invariant.
- Out of scope:
  - Changing budget-level premium escrow requirements when premium wiring is present.
  - Changing `StakeVault.setUnderwriterSlasher(...)` semantics for nonzero router inputs.
  - Removing the factory constructor requirement for an underwriter router implementation address.

## Constraints

- Preserve existing behavior for any goal with nonzero `budgetPremiumPpm` or `budgetSlashPpm`.
- Keep `0/0` as the only lane where goal-level underwriter router absence is valid.
- Keep the tree compiling without temporary compatibility shims.
- Run required Solidity verification and completion workflow before handoff.

## Acceptance Criteria

- Canonical `0/0` goal deployments return `underwriterSlasherRouter == address(0)` and do not configure the stake vault underwriter slasher.
- Premium-enabled goal deployments still deploy/configure the underwriter router exactly as before.
- `GoalTreasury` rejects missing underwriter slasher wiring when premium/slash configuration requires it.
- Regression tests cover both the zero-premium and premium-enabled lanes.

## Progress Log

- 2026-03-12: Plan created and ledger ownership recorded.
- 2026-03-12: Simplify pass removed the single-use underwriting-condition helper from `GoalFactoryCoreStackDeploy`; no broader behavior-preserving cleanup was justified within scope.

## Open Risks

- Managed preset and open preset both share the core stack finalization path, so any zero-premium change must preserve both call sites.
- Some tests use lightweight mocks that accept zero addresses more freely than production contracts; assertions need to target behavior, not mock permissiveness.

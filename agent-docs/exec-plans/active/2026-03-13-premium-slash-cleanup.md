# Premium Slash Cleanup

Status: completed
Created: 2026-03-13
Updated: 2026-03-13

## Goal

Resolve the remaining premium/slash deployment and withdrawal inconsistencies in the goal and open-budget stack so zero-premium, premium-only, and premium-plus-slash lanes each have explicit, fail-closed behavior.

## Scope

- In scope:
  - Make underwriter slasher-router wiring required only for slash-enabled lanes.
  - Let zero-premium goals skip no-op underwriter withdrawal preparation gates.
  - Remove `PremiumEscrowMode` and infer premium-module presence from `premiumEscrowImplementation`.
  - Add fail-closed prepared-stack assertions in the open budget activation path.
  - Split `IPremiumEscrow` usage by capability where consumers only need a subset of the surface.
  - Add/update regression tests for the affected deployment and withdrawal paths.
- Out of scope:
  - Reworking unrelated duplicated topology-reader view surfaces.
  - Changing premium/slash economics beyond the reviewed mismatches.
  - Broad GoalFactory implementation/deploy-script work owned by another active ledger entry.

## Constraints

- Preserve current behavior for slash-enabled open budgets.
- Keep canonical zero-premium goals and managed budgets on explicit no-premium/no-router wiring.
- Keep the tree compiling in one pass without compatibility shims unless a current boundary requires one.
- Run the required Solidity verification, size check, and completion workflow before handoff.

## Acceptance Criteria

- `budgetPremiumPpm > 0 && budgetSlashPpm == 0` budgets can deploy without underwriter slasher-router wiring.
- Zero-premium goal withdrawals do not require a no-op prepare transaction after resolution.
- Open-stack deployer/config paths infer premium-module presence solely from `premiumEscrowImplementation`.
- Open-budget activation reverts if the prepared premium-escrow result disagrees with the configured premium lane.
- Regressions cover no-premium, premium-only, and slash-enabled paths.

## Progress Log

- 2026-03-13: Plan created and coordination ledger ownership recorded.
- 2026-03-13: Removed `PremiumEscrowMode`, keyed underwriter-router wiring on `budgetSlashPpm != 0`, split premium-escrow capability interfaces, and added fail-closed premium-preparation validation in open-budget activation.
- 2026-03-13: Updated deployment/withdrawal regressions for premium-only, zero-premium, and slash-enabled paths; added premium-only activation coverage and explicit zero-slasher cobuild-withdraw coverage.
- 2026-03-13: Completion workflow finished: simplify pass applied a safe zero-router auth skip in `BudgetTCRStackActions`; coverage audit added premium-only activation regression; final review returned no findings.
- 2026-03-13: Final verification passed on the post-review tree via `pnpm -s verify:required`, `pnpm -s lint:solidity:warnings`, and `pnpm -s build:sizes`.

## Open Risks

- Deleting `PremiumEscrowMode` touches deployer storage/API/test helpers, so all call sites must move together.
- Interface splitting must stay behavior-preserving; no consumer should lose a required method during the refactor.

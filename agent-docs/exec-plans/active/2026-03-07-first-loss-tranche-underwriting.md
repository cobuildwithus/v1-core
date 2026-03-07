# 2026-03-07 First-Loss Tranche Underwriting

## Goal

Implement the underwriting redesign where budget credit is backed by bounded slashable first-loss capital rather than duration-amplified leverage.

## Scope

- `src/tcr/BudgetTCR.sol`
- `src/tcr/library/BudgetTCRCreditCapActions.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/GoalFactory.sol`
- `src/interfaces/IGoalTreasury.sol`
- `src/goals/library/GoalFactoryCoreStackDeploy.sol`
- Architecture/spec docs:
  - `ARCHITECTURE.md`
  - `agent-docs/cobuild-protocol-architecture.md`
  - `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
  - `agent-docs/references/goal-funding-and-reward-map.md`
  - `agent-docs/references/economic-considerations.md`

## Constraints / Invariants

- No `lib/**` edits.
- Preserve best-effort budget batch sync behavior and observability.
- Preserve receive-side cumulative exposure meter:
  - `goalFlow.getTotalReceivedByMember(childFlow)`.
- Preserve budget spenddown semantics:
  - duration still affects budget treasury pacing / lock time,
  - duration must not increase insured principal.
- Keep hard cutover semantics; no legacy duration-normalized slash path.

## Design

1. Budget credit-cap gating:
- replace the prior duration-amplified insured line with slashable first-loss line `coverage * budgetSlashPpm / 1e6`,
- continue applying `runwayCap` as an optional lower ceiling,
- keep gating receive-side and best-effort.

2. Budget failure slashing:
- treat `creditDrawn` as insured principal attributed to the underwriter,
- slash `min(creditDrawn, peakCov * budgetSlashPpm / 1e6)`,
- remove dependence on the legacy coverage-ratio field and `executionDuration` for slash weight calculation.

3. Goal config validation:
- keep `budgetSlashPpm != 0 => budgetPremiumPpm != 0`,
- stop requiring the legacy coverage-ratio field for slash-enabled goals.

4. Docs:
- update architecture/spec references from duration-normalized credit/slash semantics to first-loss tranche semantics.

5. Follow-up cleanup:
- remove inert legacy underwriting config/storage/getter plumbing now that runtime underwriting logic no longer uses it,
- update tests and docs to treat that removal as an interface cleanup, not a behavior change.

## Verification Plan

- Run completion workflow passes:
  1. simplify
  2. test-coverage-audit
  3. task-finish-review
- Run required Solidity gate:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`

## Risks

- Existing tests or downstream callers that assumed duration-amplified insured credit will need expectation updates.
- This is an intentional product/mechanism change: long-lived budgets no longer auto-reload insured funding solely by duration.

## Progress log

- 2026-03-07: Claimed scope in `COORDINATION_LEDGER` and traced current duration-based underwriting/slash paths.
- 2026-03-07: Applied the first-loss underwriting redesign across `BudgetTCR`, `BudgetTCRCreditCapActions`, `PremiumEscrow`, `GoalTreasury`, and `GoalFactory`.
- 2026-03-07: Updated architecture/spec/economic docs to describe slashable first-loss insured line semantics and duration-independent slashing.
- 2026-03-07: Updated targeted underwriting tests for the new semantics and added focused regressions for zero-duration and zero-slash edge cases.
- 2026-03-07: Coverage audit added a focused regression for the zero-slash `UnderwriterSlashCalculated` event shape after the legacy underwriting field was removed.
- 2026-03-07: Targeted test runs passed:
  - `forge test --match-path test/goals/PremiumEscrow.t.sol`
  - `forge test --match-path test/goals/GoalTreasuryUnderwritingConfigGuard.t.sol`
  - `forge test --match-path test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol`
  - `forge test --match-path test/BudgetTCRCreditLineGating.t.sol`
  - `forge test --match-path test/tcr/BudgetTCRRunwayCapEnforcement.t.sol`
- 2026-03-07: Completion workflow outcome:
  - simplify pass completed as no-op after manual review for behavior-preserving cleanup opportunities,
  - coverage audit added regressions for `budgetSlashPpm == 0` slash no-op and insured-line fallback when `runwayCap()` reads fail,
  - final completion audit found no new issues inside the touched underwriting scope.
- 2026-03-07: Required gates outcome:
  - `pnpm -s lint:solidity:warnings` passed (`Solidity lint warnings match baseline (8 entries)`),
  - `pnpm -s verify:required` failed twice on the same pre-existing `INVALID_BUDGET_TOPOLOGY` failures in unrelated suites:
    - `test/flows/FlowLedgerChildSyncProperties.t.sol`
    - `test/goals/BudgetStakeLedgerDerivedStateAudit.t.sol`
    - `test/goals/BudgetStakeLedgerRecipientIdMaxMerge.t.sol`
    - real-topology tests in `test/goals/UnderwritingIntegration.t.sol`.
- 2026-03-07: Follow-up accepted: remove the now-inert legacy underwriting field entirely because it has no remaining runtime effect.
- 2026-03-07: Follow-up verification reran `pnpm -s lint:solidity:warnings` successfully and `pnpm -s verify:required` reproduced the same pre-existing 12 `INVALID_BUDGET_TOPOLOGY` failures with no new regressions.

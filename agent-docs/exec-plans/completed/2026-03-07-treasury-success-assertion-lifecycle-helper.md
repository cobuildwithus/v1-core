# Treasury Success Assertion Lifecycle Helper

Status: completed
Created: 2026-03-07
Updated: 2026-03-07

## Goal

- Remove duplicated treasury-side success-assertion post-deadline lifecycle wrapper logic from `GoalTreasury` and `BudgetTreasury`.
- Keep full treasury lifecycle policy local to each treasury.

## Success criteria

- A small shared library owns the duplicated assertion clear + resolver-finalize best-effort wrapper behavior.
- `GoalTreasury` and `BudgetTreasury` still own state-machine decisions (`sync()`, grace activation, terminal target state choice).
- External ABI, events, and terminal semantics stay unchanged.
- Required Solidity verification and completion workflow pass.

## Scope

- In scope:
  - `src/goals/library/TreasurySuccessAssertionLifecycle.sol` (new)
  - `src/goals/GoalTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - Focused treasury tests and docs if needed
- Out of scope:
  - Generic shared treasury base extraction
  - Policy changes to funding, activation, success, expiry, or reassert semantics
  - Resolver ABI changes

## Risks and mitigations

1. Risk: post-deadline branch behavior drifts during extraction.
   Mitigation: keep decision selection in each treasury and only extract exact duplicated wrapper effects.
2. Risk: active treasury telemetry work conflicts on the same files.
   Mitigation: keep changes scoped to success-assertion helper regions and reconcile before commit.
3. Risk: tests miss an event or finalize-order regression.
   Mitigation: add focused parity tests around post-deadline false/fail-closed assertion handling if coverage is thin.

## Verification plan

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- completion workflow passes:
  - simplify
  - test-coverage-audit
  - task-finish-review
- rerun required checks after audit-driven edits

## Outcome

- Added shared `src/goals/library/TreasurySuccessAssertionLifecycle.sol` for:
  - pending-assertion clear helpers,
  - clear-and-best-effort-resolver-finalize handling,
  - post-deadline resolution preparation around `TreasuryPostDeadlineFinalize`.
- Refactored `GoalTreasury` and `BudgetTreasury` to use the shared lifecycle helper while keeping:
  - treasury-specific `sync()` policy local,
  - treasury-specific final state selection local,
  - treasury-specific reassert grace activation local.
- Added direct helper unit coverage in `test/goals/TreasurySuccessAssertionLifecycle.t.sol`.
- Completion workflow results:
  - simplify pass: no additional safe simplifications found,
  - test-coverage audit: no additional high-impact tests required beyond the added helper suite and existing treasury/integration coverage,
  - completion audit: no findings.
- Verification:
  - `forge test --match-path test/goals/TreasurySuccessAssertionLifecycle.t.sol` passed,
  - `forge test --match-path test/goals/BudgetTreasury.t.sol` passed,
  - targeted `UnderwritingIntegration` success-assertion tests passed,
  - `pnpm -s verify:required` passed before and after completion workflow,
  - `pnpm -s lint:solidity:warnings` passed (`Solidity lint warnings match baseline (8 entries)`).

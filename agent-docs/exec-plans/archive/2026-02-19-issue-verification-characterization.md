# Issue Verification Characterization Suite

Status: completed
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Validate the reported system-level risks with executable characterization tests that prove current behavior.
- Distinguish real risks from non-issues and document practical remediation options.

## Success criteria

- Add tests that explicitly reproduce confirmed risk behaviors (deployment coupling brittleness, historical-budget growth/liveness cost, slash timing interactions, removal terminalization gap).
- Preserve existing protocol behavior (characterization only; no production behavior changes in this pass).
- Mandatory validation passes: `forge build -q` and `pnpm -s test:lite`.

## Scope

- In scope:
  - `test/BudgetTCRDeployments.t.sol`
  - `test/BudgetTCR.t.sol`
  - `test/goals/RewardEscrowIntegration.t.sol`
  - `test/goals/GoalStakeVault.t.sol`
  - Additional focused tests for ledger/goal liveness where needed
- Out of scope:
  - Production contract refactors (CREATE2 migration, ledger indexing redesign, exit-delay policy changes)
  - Changes under `lib/**`

## Constraints

- Do not modify `lib/**`.
- Keep tests deterministic and focused on protocol invariants.
- Prefer proving behavior with minimal harness additions.

## Risks and mitigations

1. Risk: Characterization tests become flaky due to time-dependent treasury logic.
   Mitigation: Use explicit `warp`/deadline staging in setup.
2. Risk: Added test fixtures accidentally alter production semantics.
   Mitigation: Keep harness/test-only contracts local to `test/**`.

## Tasks

1. Add nonce-coupling brittleness tests for budget stack deployment.
2. Add tracked-budget growth/liveness characterization through remove+add churn.
3. Add slash timing and ledger-staleness characterization tests.
4. Add removal best-effort terminalization characterization test.
5. Run required build + lite suite and record outcomes.

## Verification

- `forge build -q`
- `pnpm -s test:lite`

## Decisions

- Added characterization-only tests (no production contract behavior changes).
- Classified canonicalization and `BudgetStakeStrategy` resolved-read behavior as non-issues after direct verification.

## Progress log

- 2026-02-19: Added nonce-coupling characterization tests in `test/BudgetTCRDeployments.t.sol`, including injected nonce-shift manager.
- 2026-02-19: Added tracked-budget growth tests in `test/goals/BudgetStakeLedgerRegistration.t.sol`.
- 2026-02-19: Added slash timing / ledger staleness characterization tests in `test/goals/GoalStakeVault.t.sol` and `test/goals/RewardEscrowIntegration.t.sol`.
- 2026-02-19: Added removal terminalization event characterization in `test/BudgetTCR.t.sol`.
- 2026-02-19: Verification passed with required baseline commands.

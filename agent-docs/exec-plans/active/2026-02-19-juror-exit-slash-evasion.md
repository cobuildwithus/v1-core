# Fix juror exit slash evasion

Status: active
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Prove and fix the economic exploit where a juror can retain snapshot voting power for a dispute, exit after 7 days, and avoid later slashing when the dispute resolves.

## Success criteria

- A regression test reproduces the pre-fix behavior (slash amount computed but zero slash applied after juror exit finalization).
- The production fix prevents that evasion path.
- Existing exit and slashing behavior remains valid for non-malicious flows.
- Mandatory repository validation passes: `forge build -q` and `pnpm -s test:lite`.

## Scope

- In scope:
  - Stake-vault + arbitrator behavior around juror exit timing and slash settlement.
  - Solidity tests covering exploit and fixed behavior.
- Out of scope:
  - Parameter-only mitigations that require governance deployment coordination.
  - Full redesign of arbitrator rounds or voting UX.

## Constraints

- Technical constraints:
  - Do not modify `lib/**`.
  - Maintain upgrade-safe storage/layout expectations.
- Product/process constraints:
  - Keep behavior compatible with existing dispute lifecycle except for exploit closure.
  - Add execution plan for this multi-file, security-sensitive change.

## Risks and mitigations

1. Risk: Fix blocks legitimate exits too aggressively.
   Mitigation: Do not block exits; instead settle slash from live stake balances so exits cannot evade settlement.
2. Risk: Test setup drifts from live integration assumptions.
   Mitigation: Use real stake-vault/arbitrator integration path for exploit regression test.

## Tasks

1. Add exploit regression test that demonstrates exit-before-slash evasion.
2. Implement slashing eligibility anchor that survives juror exit/finalization.
3. Add positive/negative tests for fixed behavior.
4. Run mandatory build and test validation.
5. Update this plan and close it once complete.

## Decisions

- Implemented: settle `slashJurorStake` from live staked balances (`_weight` / `_staked*`) instead of current juror-locked balances only.
- Lock accounting remains coherent by proportionally reducing juror-locked balances and clamping exit requests post-slash.
- Added both vault-level and arbitrator+vault integration regressions for exit-finalization slash evasion.

## Verification

- Commands to run:
  - `forge test --match-path test/ERC20VotesArbitratorStakeVaultExitEvasion.t.sol --match-test test_slashVoter_regression_exitFinalizationCannotBypassSlash -vv`
  - `forge test --match-path test/goals/GoalStakeVault.t.sol --match-test test_slashJurorStake_regression_exitFinalizationCannotZeroSlashableStake -vv`
  - `forge test --match-path test/goals/GoalStakeVault.t.sol --match-test "test_setJurorSlasher_and_slashJurorStake_proportionalAcrossAssets|test_slashJurorStake_doesNotOverslashGoalWeightFromRounding" -vv`
  - `forge build -q`
  - `pnpm -s test:lite`
  - `bash scripts/check-agent-docs-drift.sh`
  - `bash scripts/doc-gardening.sh --fail-on-issues`
- Expected outcomes:
  - Regression tests failed pre-fix, then passed post-fix.
  - `forge build -q` passed.
  - `pnpm -s test:lite` failed due pre-existing compile error in `src/tcr/BudgetTCRDeployer.sol` (`UNEXPECTED_TREASURY_ADDRESS` undeclared), unrelated to this change set.
  - Agent docs drift/doc-gardening checks passed.

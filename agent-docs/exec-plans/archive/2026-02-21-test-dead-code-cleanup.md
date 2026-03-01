# 2026-02-21 Test Dead Code Cleanup

## Goal
Remove high-confidence dead/unused code in test harnesses, mocks, and test files without changing runtime behavior.

## Scope
- `test/mocks/MockIncompatibleVotesToken.sol`
- `test/ERC20VotesArbitratorInitConfigUpgrade.t.sol`
- `test/GeneralizedTCRInitSubmission.t.sol`
- `test/BudgetTCRFlowRemovalLiveness.t.sol`
- `test/GeneralizedTCRSubmissionDepositsHardening.t.sol`
- `test/GeneralizedTCRSubmissionDepositsInitValidation.t.sol`
- `test/goals/GoalRevnetIntegration.t.sol`
- `test/goals/RewardEscrowIntegration.t.sol`
- `test/goals/RewardEscrow.t.sol`
- `test/goals/RewardEscrowSweepLockExploit.t.sol`
- `test/utils/FlowSuperfluidFrameworkDeployer.sol`

## Constraints
- No `lib/**` edits.
- Keep behavior unchanged; remove only symbols with direct no-reference evidence.
- Respect existing dirty worktree and avoid reverting unrelated modifications.

## Plan
1. Identify dead candidates with cross-reference scans and explorer subagents.
2. Remove only confirmed-dead symbols/contracts/imports/vars.
3. Verify with required Solidity build and test suite.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

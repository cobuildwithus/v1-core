# 2026-03-11 Factory Default Spend Policy Options

Status: completed
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Deploy canonical default spend-policy clones during implementations deployment.
- Wire those defaults into newly deployed `GoalFactory` instances.
- Let `DeployGoalFromFactory` accept a lightweight `default` option while keeping the onchain `GoalFactory.deployGoal(...)` surface address-based.

## Acceptance Criteria

- `DeployGoalFactoryImplementations` deploys an underlying `LinearSpendPolicy` implementation plus initialized default goal/budget policy clones and records them in deployment artifacts/TOML.
- `DeployGoalFactory` loads those default policy addresses from env/TOML and passes them into `GoalFactory`.
- `GoalFactory` stores validated `DEFAULT_GOAL_SPEND_POLICY` and `DEFAULT_BUDGET_SPEND_POLICY`.
- `DeployGoalFromFactory` resolves `default` options for goal and budget policies against the factory defaults while still accepting explicit addresses.
- Tests cover the new default-policy deployment wiring, constructor validation, and script resolution behavior.

## Scope

- `src/goals/GoalFactory.sol`
- `src/goals/policies/LinearSpendPolicy.sol`
- `script/DeployGoalFactoryImplementations.s.sol`
- `script/DeployGoalFactory.s.sol`
- `script/DeployGoalFromFactory.s.sol`
- `test/goals/GoalFactorySpendPolicyDeploy.t.sol`
- `test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol`
- `test/mocks/FakeUMATreasurySuccessResolver.t.sol`

## Constraints

- Keep `GoalFactory.deployGoal(...)` address-based; do not introduce onchain option enums.
- Default policy instances must be initialized clones; the raw `LinearSpendPolicy` implementation remains init-locked.
- Preserve custom-policy support.
- Require an explicit `*_SPEND_POLICY_OPTION=default` opt-in for factory-default resolution; missing or empty options must still fail fast.
- Do not touch unrelated dirty files already present in the worktree.

## Outcome

1. `DeployGoalFactoryImplementations` now deploys a reusable `LinearSpendPolicy` implementation plus canonical initialized default goal/budget policy clones and records all three addresses in the text/TOML artifacts.
2. `DeployGoalFactory` now loads the default policy addresses from env/TOML, threads them through `GoalFactoryPairDeployer`, and records them in the factory deployment artifact.
3. `GoalFactory` now stores `DEFAULT_GOAL_SPEND_POLICY` and `DEFAULT_BUDGET_SPEND_POLICY` immutables and rejects malformed default spend-policy contracts during construction.
4. `DeployGoalFromFactory` now resolves explicit spend-policy addresses first, supports an explicit `default` option for factory-default resolution, and preserves required-env failures when no address or option is supplied.
5. Script wiring tests now cover canonical default artifact outputs, explicit-address precedence, invalid option handling, and missing-option required failures.

## Verification

- `forge test --match-path test/goals/GoalFactorySpendPolicyDeploy.t.sol --skip test/juicebox/**`
- `forge test --match-path test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol --skip test/juicebox/**`
- `forge test --match-path test/mocks/FakeUMATreasurySuccessResolver.t.sol --skip test/juicebox/** --skip test/goals/ManagedBudgetController.t.sol`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s verify:required`

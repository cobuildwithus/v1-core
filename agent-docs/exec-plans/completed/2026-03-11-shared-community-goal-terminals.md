# Shared Community And Goal Terminals

## Goal

Implement the shared-terminal funding cutover so:
- goal funding resolves its payment token and source revnet from the registered goal treasury at pay time,
- community routing uses one shared payment terminal with per-community registration,
- goal deployment can inherit funding context from a community registry or an explicit deploy-time funding config,
- community listings reject goals whose treasury funding context does not match the community.

## Why

- The current code assumes one global COBUILD token/revnet for all goal and community funding.
- The requested behavior requires community-scoped payment sources and shared route-setter infrastructure.
- The current factory/deploy tests and scripts still encode the dedicated terminal-per-community model.

## Scope

- Refactor `CobuildTerminal`, `CobuildPaymentTerminal`, and `CobuildPaymentTerminalFactory` to the shared-terminal model.
- Refactor `GoalFactory` to use deploy-time `FundingContext` and add `deployGoalForCommunity`.
- Harden `CommunityGoalRegistry` to validate treasury/stake-vault funding lineage.
- Update constructor/deployment call sites, scripts, mocks, and comprehensive tests.
- Update architecture/spec docs if the behavior-level model changes materially.

## Out Of Scope

- Any changes under `lib/**`.
- Release/versioning flows.
- Unrelated cleanup in routing or treasury modules beyond what is required to compile and verify this cutover.

## Risks

- Constructor and interface churn can break deploy scripts and fixtures in many places.
- Goal/community routing now depends on treasury and stake-vault runtime contract checks; missed revert-path tests would leave gaps.
- Docs currently describe the older dedicated-terminal deployment model and may need synchronization.

## Verification

- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

# Treasury Sync / Success Assertion Base

Status: completed
Created: 2026-03-13
Updated: 2026-03-16

## Goal

Unify the duplicated treasury success-assertion accessor/event-emitter plumbing and the shared `_syncFlowRate` skeleton across `GoalTreasury` and `BudgetTreasury`, while preserving the treasury-specific target-rate computation and lifecycle gating.

## Scope

- In scope:
  - `src/goals/GoalTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/goals/TreasurySuccessAssertionMixin.sol`
  - shared treasury interface files needed to support the new base-level implementations
  - focused treasury/goal/budget regression tests if the refactor exposes a coverage gap
- Out of scope:
  - changing goal or budget lifecycle policy
  - changing spend-policy math or success-assertion gating semantics
  - changing terminal side-effect ordering

## Constraints

- Preserve exact event signatures and externally visible state/query behavior.
- Keep the only semantic difference in the flow-rate path at the target-rate computation hook.
- Avoid widening authority or changing inheritance order in a way that affects initializer/runtime behavior.
- Respect the dirty shared worktree and preserve unrelated active-lane edits.

## Acceptance Criteria

- Common pending/reassert/resolved/flow/balance accessor wrappers are removed from both treasuries and satisfied by shared base code.
- Common success-assertion emitter hooks are implemented once in shared base code.
- `_syncFlowRate` exists once in shared base code and delegates only the treasury-specific target-rate computation and any minimal supporting hooks.
- Verification and completion workflow pass, or any unrelated required-gate failure is explicitly justified.

## Risks

- Interface/base reshaping can accidentally change override resolution or event visibility even if runtime logic is unchanged.
- Shared `_syncFlowRate` extraction must not alter goal-vs-budget sync mode selection, emitted balances, or remaining-time reporting.

## Decisions

- Use a new abstract `TreasuryFlowRateAssertionBase` above `TreasurySuccessAssertionMixin` instead of further inflating the mixin.
- Keep `TreasurySuccessAssertionMixin` as the lower-level lifecycle/state helper and leave its event hooks abstract.
- Keep treasury-facing selector availability stable by having `IBudgetTreasury` and `IGoalTreasury` inherit small shared runtime/event interfaces rather than deleting those members outright.

## Current Notes

- The first extraction attempt failed because the mixin owned both event declarations and interface-resolution wrappers, which created duplicate event definitions and override pressure.
- The current implementation path is to finish wiring both treasuries onto the new base, then confirm selector users like `StakeVault` still compile through inherited interface members.

## Outcome

- Added `TreasuryFlowRateAssertionBase` to centralize the shared `targetFlowRate()` body, `_syncFlowRate()` shell, and common success-assertion event emitters.
- Kept the concrete treasuries on treasury-specific `_computeTargetFlowRate(...)` hooks while preserving the required Solidity leaf override shims for interface conformance.
- Added shared runtime/event interfaces used by the new base and by compatibility call sites/tests.
- Preserved selector/event compatibility where needed by restoring direct treasury-interface runtime view declarations and updating selector/event-qualified tests to use the shared interfaces where appropriate.

## Verification

- Passed: `forge build -q --skip test --skip script src/goals/BudgetTreasury.sol src/goals/GoalTreasury.sol src/goals/TreasurySuccessAssertionMixin.sol src/goals/TreasuryFlowRateAssertionBase.sol src/interfaces/IBudgetTreasury.sol src/interfaces/IGoalTreasury.sol src/interfaces/ITreasuryFlowRateSyncEvents.sol src/interfaces/ITreasuryRuntimeViews.sol src/interfaces/ITreasurySuccessAssertionEvents.sol src/goals/StakeVault.sol`
- Passed: `pnpm -s verify:required`
- Passed: `pnpm -s lint:solidity:warnings`
- Passed: `pnpm -s build:sizes`
- Passed targeted: `forge test --match-path test/goals/BudgetTreasury.t.sol --match-test "test_targetFlowRate_zeroWhenNotActive|test_sync_activeWithPendingSuccessAssertion_atDeadline_settledFalse_emitsGraceEvents|test_registerAndClearSuccessAssertion_emitsEventsAndResetsPendingState"`
- Passed targeted: `forge test --match-path test/goals/StakeVault.t.sol --match-test "test_slashUnderwriterStake_bestEffortGoalFlowSyncDoesNotRevertWhenFlowLookupReverts|test_slashUnderwriterStake_bestEffortGoalFlowSync_doesNotForwardLegacyBudgetTreasuryLookup"`
- Re-run note: a later `pnpm -s verify:required` rerun failed only in unrelated `DeployGoalFactoryScriptWiringTest` with `vm.isFile: the path  is not allowed to be accessed for read operations`.

## Completion Notes

- Simplify / coverage / finish-review were completed locally after repeated audit-subagent transport failures (`stream disconnected before completion` / interrupted sessions), with no additional behavior-preserving simplifications or missing high-impact tests identified beyond the targeted treasury and StakeVault checks above.

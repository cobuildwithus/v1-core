# Agent Memory

Optional, living memory for helpful repo learnings.

- Add concise, high-signal notes when they improve future speed/accuracy; skip trivial or temporary details.
- Organize notes with short labels (for example: `Architecture`, `Storage`, `Testing`, `Gotchas`) so they stay scannable.
- Prefer durable facts (patterns, pitfalls, commands, ownership, architecture links) over task transcripts.
- Use discretion: you do not need to add notes every time.

## Helper: Architecture Docs

- `agent-docs/cobuild-protocol-architecture.md`

## Helper: Verification

- Run `forge build` after contract and config changes.
- Run `pnpm -s test:lite` for the default test validation pass.
- If you add/rename scripts, keep `package.json` scripts in sync.

## Flows: Allocation Gas Ceilings (Feb 18, 2026)

- Gas profiler tests live in `test/flows/FlowAllocationsGas.t.sol`.
- Repro command for dynamic profiling:
  - `RUN_GAS_ENV_PROFILE=true GAS_PROFILE_RECIPIENT_COUNT=<N> GAS_PROFILE_CHANGED_COUNT=<C> forge test -vv --match-test test_gasProfile_envProfile --match-path test/flows/FlowAllocationsGas.t.sol`
- Empirical cap under `16,777,216` gas:
  - `C=50` changed profile: max `N=704` (`16,771,604` gas); `N=705` is over (`16,785,356`).
  - Full-delta profile (`C=N`, even counts): max `N=110` (`16,598,928` gas); `N=112` is over (`16,900,598`).

## Staking: Goal-Scoped Weight (Feb 18, 2026)

- `src/goals/GoalStakeVault.sol` tracks two stake balances:
  - `goalToken` stake converts to cobuild-equivalent weight using the goal revnet ruleset weight.
  - `cobuildToken` stake counts 1:1 as allocation weight.
- Conversion aligns with inverse Nana/JBX mint math (`amount = tokenCount * weightRatio / weight`) using one source (`goalRulesets.currentOf(goalRevnetId).weight`).
- `src/allocation-strategies/GoalStakeVaultStrategy.sol` maps `allocationKey` to caller address and reads live weight from `GoalStakeVault`.

## Rewards: Goal Reward Escrow (Feb 19, 2026)

- `src/goals/RewardEscrow.sol` receives the Flow manager-reward stream via `managerRewardPool`.
- `src/goals/GoalTreasury.sol` finalizes rewards by calling `RewardEscrow.finalize(uint8(finalState))` inside `_finalize`, after stopping flow and before stake-vault unlock.
- Reward escrow v2 tracks allocation stake-time checkpoints per budget from goal-flow allocation updates.
- Only budgets that are `Succeeded` by goal finalization contribute reward points.
- Goal success gates redemption: `claim = rewardPoolSnapshot * userSuccessfulPoints / totalSuccessfulPointsSnapshot`.
- Failed/expired/unresolved budgets contribute zero reward points.

## Testing: Flow Harness Scope (Feb 18, 2026)

- Prefer root `CustomFlow` in tests whenever internal hooks are not required.
- `test/flows/helpers/FlowTestBase.t.sol` now types `flow` as `CustomFlow`; use `_harnessFlow()` only in tests that need internal state hooks.
- Keep `test/harness/TestableCustomFlow.sol` limited to internal-only test controls:
  - `addChildForTest`, `queueChildForUpdate`
  - `setRateSnapshot`, `getOldChildRate`, `getRateSnapshotTaken`, `isChildQueued`
  - `setBonusUnits` (only for synthetic child-flow sync scenarios with mock children)
  - `exposed_setChildrenAsNeedingUpdates` (only for direct benchmarking/internal path tests)
- Use public APIs instead of harness shims when possible:
  - `workOnChildFlowsToUpdate` instead of internal worker wrappers
  - `childFlowRatesOutOfSync` / `getChildFlows()` instead of queue/child-count internals

## Testing: Suite Modularization (Feb 18, 2026)

- Large suites were split into focused files with shared abstract bases:
  - `test/flows/FlowAllocations*.t.sol`, `test/flows/FlowInitializationAndAccess*.t.sol`, `test/flows/FlowChildSync*.t.sol`
  - `test/ERC20VotesArbitrator*.t.sol`
  - `test/GeneralizedTCR*.t.sol`
  - `test/GeneralizedTCRSubmissionDeposits*.t.sol`
  - `test/invariant/TCRAndArbitrator.invariant.t.sol` + `test/invariant/Arbitrator.invariant.t.sol`
- Keep monolithic setup out of leaf suites: place shared fixture/deploy helpers in one base file per domain.
- Preserve test function names when splitting to avoid breaking existing filters and CI selection habits.

## Collaboration Preference (Feb 19, 2026)

- When multiple agents are editing in parallel, default to continuing work in-place while touching only files already in the current agent's scope.

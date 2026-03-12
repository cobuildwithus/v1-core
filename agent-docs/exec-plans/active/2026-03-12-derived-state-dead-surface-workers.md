# 2026-03-12 Derived State + Dead Surface Workers

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Run four codex-4 worker lanes in parallel for the requested simplifications:
  - derive `StakeVault.goalResolved()` from `goalResolvedAt`
  - derive `PremiumEscrow.closed()` from `closedAt`
  - derive `requireZeroPremiumAndSlashRates` from `premiumEscrowMode`
  - remove the safe dead/legacy surfaces in the requested set

## Scope

- Direct edit lanes:
  - `src/goals/StakeVault.sol`
  - `src/goals/PremiumEscrow.sol`
  - `src/interfaces/IBudgetStackDeployer.sol`
  - `src/tcr/BudgetTCRDeployer.sol`
  - `src/tcr/library/BudgetTCRStackActions.sol`
  - `src/goals/policies/NoopBudgetGatePolicy.sol`
  - `src/interfaces/IGoalLedgerStrategy.sol`
- Read-only blocker analysis candidates:
  - `src/tcr/library/BudgetTCRInitValidation.sol`
  - `src/goals/library/GoalFactoryManagedPresetDeploy.sol`
  - `src/goals/GoalFactory.sol`

## Constraints

- Workers must use the shared-worktree helper flow from `../workspace-docs/codex-workers.md`.
- Launch with `../workspace-docs/bin/codex-workers --profile 4 --sandbox workspace-write --full-auto`.
- Child workers must not commit and must not run repo-wide verification.
- Parent owns final diff review, any cross-lane follow-up edits, required verification, completion workflow, and commit flow.
- The helper runs child Codex sessions in the same live worktree, so file ownership must stay disjoint.
- Existing active ownership in `COORDINATION_LEDGER.md` already claims:
  - `src/tcr/library/BudgetTCRInitValidation.sol`
  - `src/goals/library/GoalFactoryManagedPresetDeploy.sol`
  - `src/goals/GoalFactory.sol`
- Any lane that needs one of those files must fail closed and report a concrete blocker instead of editing around it.
- The dead-surface lane must also fail closed if deleting `NoopBudgetGatePolicy` or `IGoalLedgerStrategy` would require touching tests/docs or assumes those import paths are not public package API.

## Lane Map

1. `codex-worker-stakevault-derived-goal-resolved`
   - derive `goalResolved()` from `goalResolvedAt != 0`
   - keep ABI and current resolution/withdrawal behavior
2. `codex-worker-premium-escrow-derived-closed`
   - derive `closed()` from `closedAt != 0`
   - keep close/slash/claim semantics unchanged
3. `codex-worker-budgettcr-derived-no-premium-flag`
   - remove stored deployer bool only if the `BudgetTCRInitValidation.sol` dependency is not actively owned elsewhere
   - otherwise return a blocked report with the exact file conflict and smallest safe next step
4. `codex-worker-dead-surface-prune`
   - hard-delete `NoopBudgetGatePolicy` / `IGoalLedgerStrategy` only if safe inside lane
   - treat `initializeManagedController(...)` cleanup as blocked while `GoalFactory*.sol` remain actively owned elsewhere

## Launch Command

- `../workspace-docs/bin/codex-workers --profile 4 --sandbox workspace-write --full-auto -j 4 ...`

## Parent Integration Checklist

1. Review each worker's final message and live diff.
2. Reconcile any non-overlapping follow-up edits locally.
3. Run:
   - `pnpm -s verify:required`
   - `pnpm -s lint:solidity:warnings`
   - `pnpm -s build:sizes`
4. Run completion workflow passes in order:
   - simplify
   - test-coverage-audit
   - task-finish-review
5. Remove worker temp files/run outputs before handoff.

## Outcome

- Implemented:
  - `StakeVault` now derives `goalResolved()` from `goalResolvedAt`, normalizes a block-0 resolution latch to `1`, and keeps internal guards timestamp-derived.
  - `PremiumEscrow` now derives `closed()` from `closedAt` and keeps close/slash/claim gating behavior unchanged.
  - invariant stake-vault test double now derives `goalResolved()` from `markCallCount`.
  - focused `StakeVault` regression added for the block-0 latch normalization.
- Blocked with concrete reasons:
  - deployer zero-rate flag derivation blocked by active ownership of `src/tcr/library/BudgetTCRInitValidation.sol`
  - dead-surface cleanup blocked by active ownership of `GoalFactory*.sol` plus out-of-scope test/doc references for `NoopBudgetGatePolicy` and `IGoalLedgerStrategy`
- Completion workflow:
  - simplify: landed one behavior-preserving cleanup in `StakeVault` plus invariant test-double dedupe
  - test-coverage-audit: no new tests needed beyond the later review-driven block-0 regression
  - task-finish-review: first pass found the block-0 latch edge; parent fixed it and reran the review pass, which returned no findings
- Verification evidence:
  - worker-targeted offline Forge suites passed for `StakeVault`, `PremiumEscrow`, and the directly affected `BudgetTreasury` / `BudgetTCR` premium-escrow paths before unrelated shared-tree compile drift widened
  - parent-required compile-based gates (`verify:required`, `lint:solidity:warnings`, `build:sizes`) failed for credibly unrelated dirty-tree changes in other active lanes, not in this task's files

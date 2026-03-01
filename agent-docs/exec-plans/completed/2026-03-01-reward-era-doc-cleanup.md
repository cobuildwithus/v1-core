# Reward-Era Doc Cleanup

Status: completed
Created: 2026-03-01
Updated: 2026-03-01

## Goal

- Align canonical docs and active-plan inventory with the post-RewardEscrow underwriting cutover so runtime/docs surface no longer implies the removed rewards regime.

## Success criteria

- Canonical docs no longer reference removed `RewardEscrow`/points-era paths as current behavior.
- RewardEscrow-era stale plans are no longer kept under `agent-docs/exec-plans/active/`.
- `GoalTreasury` no longer depends on redundant `IStakeVaultUnderwriterConfig`; direct `IStakeVault` call compiles.
- Required Solidity verification gate (`pnpm -s verify:required`) passes.

## Scope

- In scope:
  - Update architecture/reference/security/reliability docs that currently describe RewardEscrow as active runtime.
  - Archive stale RewardEscrow-era active execution plans to reduce active-folder drift.
  - Remove redundant `src/interfaces/IStakeVaultUnderwriterConfig.sol` usage and interface file.
- Out of scope:
  - Rewriting historical archived/completed plans.
  - Protocol behavior changes beyond the tiny underwriter-slasher setter interface simplification.

## Constraints

- Technical constraints:
  - Preserve hard-cutover runtime behavior (no backward-compat shims).
  - Keep edits outside `lib/**`.
- Product/process constraints:
  - Keep `COORDINATION_LEDGER.md` active ownership updated during this task.
  - Preserve immutable historical docs under completed/archive plan snapshots (move only, no rewrite).

## Risks and mitigations

1. Risk: Moving the wrong active plans could conflict with genuinely in-flight work.
   Mitigation: Only move plans matching RewardEscrow-era surface (`RewardEscrow`/`IRewardEscrow`/legacy points terms); keep current underwriter/premium-escrow plans in place.
2. Risk: Doc rewrites could desync with current code semantics.
   Mitigation: Cross-check updated statements against current Solidity surfaces before handoff.

## Tasks

1. Update key canonical docs to remove RewardEscrow-as-current references and reflect premium escrow + underwriter slasher routing.
2. Move stale RewardEscrow-era files from `exec-plans/active` to `exec-plans/archive`.
3. Remove redundant underwriter-config adapter interface and switch `GoalTreasury` callsite to `IStakeVault`.
4. Run required verification and summarize resulting diffs/check outputs.

## Progress log

- 2026-03-01: Updated canonical docs (`goal-funding-and-reward-map`, `module-boundary-map`, `protocol-audit-deep-dive`, lifecycle/spec, security/reliability/quality, and index references) to current premium-escrow/underwriter model.
- 2026-03-01: Moved 39 RewardEscrow-era plan files from `agent-docs/exec-plans/active/` to `agent-docs/exec-plans/archive/` to remove active-folder drift.
- 2026-03-01: Simplified `GoalTreasury.configureUnderwriterSlasher` to call `_stakeVault.setUnderwriterSlasher(...)` directly and deleted `src/interfaces/IStakeVaultUnderwriterConfig.sol`.
- 2026-03-01: Ran `pnpm -s verify:required`; run failed on one existing test (`test/goals/BudgetTreasury.t.sol::test_finalize_terminalSideEffects_pruneHookFailure_isBestEffort`, `assertion failed: 0 != 1`), with 1044 tests passing.

## Decisions

- Apply hard-cutover docs policy: historical RewardEscrow records stay as archived snapshots; active canonical docs describe only current underwriting/premium-escrow runtime.
- Use direct `IStakeVault.setUnderwriterSlasher` call in `GoalTreasury` and delete redundant one-function adapter interface.

## Verification

- Commands to run:
  - `rg -n "RewardEscrow|IRewardEscrow|successSettlementRewardEscrowPpm|points accrual|matured stake-time" agent-docs/*.md agent-docs/references/*.md agent-docs/product-specs/*.md`
  - `rg -n "RewardEscrow|IRewardEscrow|successSettlementRewardEscrowPpm" agent-docs/exec-plans/active`
  - `pnpm -s verify:required`
- Expected outcomes:
  - Canonical docs are cut over from RewardEscrow-era claims.
  - Active plans are free of stale RewardEscrow-era plan files (except living context that intentionally references completed history).
  - Solidity gate passes with interface simplification.
Completed: 2026-03-01

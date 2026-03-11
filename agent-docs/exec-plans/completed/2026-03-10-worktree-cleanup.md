# Worktree Cleanup

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Clean the shared worktree so active execution plans only represent genuinely unfinished work, stale ledger claims are removed, and the resulting hygiene updates are committed without rewriting unrelated protocol changes.

## Scope

- `agent-docs/exec-plans/active/**`
- `agent-docs/exec-plans/completed/**`
- `agent-docs/generated/doc-inventory.md`
- Verification-blocker fixes needed to make the current dirty Solidity/test worktree green:
  - `src/goals/BudgetStakeLedger.sol`
  - `src/tcr/BudgetTCRFactory.sol`
  - `test/BudgetTCRFactoryCoverage.t.sol`
  - `test/goals/BudgetStakeLedgerCoverageCutover.t.sol`
  - `test/mocks/FakeUMATreasurySuccessResolver.t.sol`

## Constraints

- Do not revert or rewrite unrelated source/test/deploy changes already present in the worktree.
- Preserve historical plan contents; when a plan is no longer active, move it instead of rewriting its history.
- Keep only genuinely active work in `agent-docs/exec-plans/active/`.
- If the cleanup touches only docs/plan files, skip repo verification per policy.

## Acceptance Criteria

- `agent-docs/exec-plans/active/` no longer contains clearly completed/done/blocked plans that should live elsewhere.
- `COORDINATION_LEDGER.md` contains only current active ownership.
- Any active plans left in place still correspond to genuinely unfinished work or explicitly documented blockers.
- The current dirty Solidity/test worktree passes `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.
- Cleanup changes are committed with `scripts/committer`.

## Progress Log

- 2026-03-10: Audited dirty worktree, active-plan inventory, and coordination ledger state.
- 2026-03-10: Found a stale ledger claim referencing a missing active plan file and removed it while claiming this cleanup task.
- 2026-03-10: Ran `pnpm -s verify:required`; current blockers are four `BudgetTCRFactoryCoverage` expectation mismatches, two `BudgetStakeLedgerCoverageCutover` topology-registry expectation mismatches, and one deploy-script wiring out-of-gas failure.
- 2026-03-10: Moved terminal-status and otherwise finished execution plans out of `agent-docs/exec-plans/active/` and confirmed no remaining active plan advertises a completed/blocked/cancelled status.
- 2026-03-10: Fixed the dirty worktree gate failures by making the factory coverage strategies capability-aware, hardening the topology-registry coverage harness/assertions, aligning `BudgetStakeLedger.previewChangedBudgetTreasuries(...)` with resolved-goal terminal no-op behavior, and restoring the deploy-history content assertion in the UMA success resolver test.
- 2026-03-10: Ran completion workflow passes (`simplify`, `test-coverage-audit`, `task-finish-review`) and incorporated the review follow-ups into the same change set.
- 2026-03-10: Re-ran `pnpm -s verify:required` twice and `pnpm -s lint:solidity:warnings`; all required gates passed on the current tree.
- 2026-03-10: Ran `bash scripts/doc-gardening.sh`; doc inventory regenerated cleanly with `Issues found: 0`.

## Open Risks

- Parent-repo cleanup is complete; an untracked `.DS_Store` remains inside `lib/v4-periphery`, which stays out of scope unless the user explicitly approves `lib/**` cleanup.

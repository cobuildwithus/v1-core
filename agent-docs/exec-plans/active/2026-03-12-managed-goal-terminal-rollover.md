# 2026-03-12 Managed Goal Terminal Rollover

## Goal

Stop burn-by-default terminal residual handling for managed maintainer goals on successful resolution.
Instead, convert goal residual value into the parent/community token, queue it on the canonical community split hook,
and release it into historical backlog after a cooldown so the existing routing signal allocates it.

## Scope

- Add managed-goal rollover configuration on `GoalTreasury`.
- Add split-hook queued-rollover bookkeeping and permissionless release entrypoints.
- Wire managed preset factory deployments to enable rollover with a fixed cooldown.
- Add regression tests for:
  - goal success residual rollover queueing,
  - split-hook delayed release into historical backlog,
  - managed factory wiring.
- Update lifecycle/architecture/reference docs for the new managed-only terminal policy.

## Constraints

- Preserve burn semantics for open goals and non-rollover terminal paths.
- Keep rollover permissionless after queueing; no mutable successor address.
- Reuse canonical community routing (`CobuildSplitHook` historical backlog), not explicit-route seeding.
- Avoid unbounded release loops; chunk queued-release processing.
- Do not revert or overwrite unrelated local worktree edits.

## Plan

1. Extend treasury and split-hook interfaces for managed rollover config and delayed queue/release.
2. Implement managed-success residual conversion in `GoalTreasury`:
   - downgrade goal SuperToken residual,
   - cash out goal tokens into parent/community token through the canonical goal cash-out terminal,
   - queue delayed rollover on the canonical community split hook.
3. Implement split-hook queued rollover storage, events, and permissionless release-to-backlog flow.
4. Wire managed preset factory deployments to set a fixed rollover cooldown while open preset remains burn-only.
5. Add regression tests and doc updates.
6. Run required verification + completion workflow passes, then commit touched files.

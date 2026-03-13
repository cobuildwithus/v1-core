# GoalFactory Typed Deploy Paths (2026-03-13)

## Goal

Replace `GoalFactory`'s internal preset union deploy path with typed open/managed internal deploy flows while preserving the public API and current deployment behavior.

## Scope

- Refactor `src/goals/GoalFactory.sol` to remove `InternalDeployParams`.
- Split `_deployGoal(...)` into preset-specific internal deploy entrypoints.
- Extract only truly shared validation and deployment steps that are used by both presets.
- Add or update focused tests only if the refactor needs regression coverage beyond the existing suite.

## Constraints

- Preserve current external factory entrypoints and parameter structs.
- Preserve open vs managed control-plane semantics and fail-closed validation behavior.
- Keep runtime deployment clone-based; do not introduce new constructor deployment paths.
- Avoid touching unrelated dirty files already present in the worktree.

## Acceptance Criteria

- `GoalFactory` no longer funnels open and managed params through a union struct with invalid combinations.
- Open-only and managed-only deployment paths read as typed flows with flatter branching.
- Shared helpers are limited to common validation, funding-context resolution, revnet deployment, and core-stack finalization/setup.
- Required Solidity verification, warning, and size gates pass after completion-workflow follow-ups.

## Progress Log

- 2026-03-13: Read required architecture, lifecycle, security, reliability, and process docs.
- 2026-03-13: Confirmed current `GoalFactory` still funnels `OpenGoalParams` and `ManagedGoalParams` into `InternalDeployParams`, then branches heavily inside `_deployGoal(...)`.
- 2026-03-13: Added coordination-ledger row for the active `GoalFactory` refactor lane.
- 2026-03-13: Replaced the internal union deploy path with typed `_deployOpenGoal(...)` and `_deployManagedGoal(...)` flows plus shared validation/deployment helpers, while retaining the public `GoalPreset` enum surface for deployment-script compatibility.
- 2026-03-13: Coverage follow-ups added managed-community wrapper regressions for `MANAGED_SAFE_REQUIRED`, `MANAGED_PRESET_REQUIRES_ZERO_PREMIUM_AND_SLASH`, and `INVALID_ASSERTION_CONFIG`.
- 2026-03-13: Verification completed on the final tree:
  - `TEST_SCOPE_THREADS=0 TEST_SCOPE_BUILD_THREADS=0 TEST_SCOPE_SKIP_SHARED_BUILD=1 scripts/test-scope.sh goals --match-contract '^GoalFactoryUnderwritingSlashConfigGuardTest$'` passed (`37/37`).
  - `pnpm -s verify:required` passed after the refactor and again after the final coverage follow-up.
  - `pnpm -s lint:solidity:warnings` passed.
  - `pnpm -s build:sizes` passed with `GoalFactory` runtime size `18,798` bytes and `5,778` bytes of runtime margin.

## Open Risks

- No task-specific open risks remain after the added wrapper regressions and final verification passes.

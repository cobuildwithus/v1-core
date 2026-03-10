# Real TCR Test Cutover

## Goal

Move mock-backed TCR submission-deposit coverage onto a concrete protocol implementation wherever the tests only need canonical TCR behavior.

## Why

- Current deposit-path tests exercise `MockGeneralizedTCR`, an abstract test double, even though the repo now has concrete TCR implementations.
- Using a concrete implementation gives better confidence that submission-deposit logic is wired correctly through a real initializer and hook surface.

## Scope

- Add a lightweight `CommunityGoalRegistry`-based test harness with minimal local dependency stubs.
- Convert submission-deposit behavior/fallback tests that do not require mock-only exposed setters or custom hook mutation.
- Keep mock-backed tests only where they rely on abstract-hook behavior or direct storage exposure not available on concrete contracts.

## Constraints

- Test-only change; do not touch production contracts.
- Preserve existing unrelated worktree edits.
- Keep the replacement focused on repo-owned protocol contracts, not external dependency mocks.

## Risks

- Harness setup for `CommunityGoalRegistry` adds local dependency stubs; those must stay minimal and behaviorally accurate for the exercised paths.
- Over-conversion could hide tests that intentionally depend on mock-only mutation/exposure helpers.

## Verification

- Targeted Forge runs for the touched TCR submission-deposit suites.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
Status: completed
Updated: 2026-03-10
Completed: 2026-03-10

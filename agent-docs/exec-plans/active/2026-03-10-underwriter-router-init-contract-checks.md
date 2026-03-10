# Underwriter Router Init Contract Checks

Status: in_progress
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Make `UnderwriterSlasherRouter` fail fast during initialization when required typed dependencies are EOAs or otherwise have no runtime code, instead of accepting them and surfacing failures later during slash/conversion/forwarding flows.

## Scope

- In scope:
  - Add init-time contract-code validation for router dependencies that are expected to be contracts.
  - Keep constructor and clone initialization semantics aligned.
  - Add focused regression tests for constructor and clone-init rejection paths.
- Out of scope:
  - Changing slash-routing best-effort semantics after successful initialization.
  - Changing `goalFundingTarget` requirements beyond the existing nonzero check.
  - Changes under `lib/**`.

## Constraints

- Preserve the all-zero constructor sentinel used for implementation instances.
- Reject invalid dependencies before downstream external calls or state writes.
- Keep error reporting explicit and test-backed.
- Run required Solidity verification before handoff:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`

## Acceptance Criteria

- Router initialization reverts when a required typed dependency address has no code.
- Existing valid constructor and clone-init paths still succeed.
- Regression tests cover the new fail-fast behavior.
- Required verification passes.

## Progress Log

- 2026-03-10: Plan created for init-time dependency hardening and focused regression coverage.
- 2026-03-10: Added `NOT_A_CONTRACT` init-time gates for required typed dependencies in `UnderwriterSlasherRouter` and kept zero-address precedence intact.
- 2026-03-10: Added constructor and clone-init regressions for no-code dependencies, plus clone-init parity coverage for goal/cobuild token mismatch and super-token underlying mismatch.
- 2026-03-10: Required verification is currently blocked by unrelated shared-worktree compile errors in other active files; `pnpm -s verify:required` fails during compile before reaching the router suite.

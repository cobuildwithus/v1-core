# UMA Success Assertion Library Refactor

## Goal
Extract duplicated treasury-level UMA success assertion plumbing into a shared library while preserving treasury-specific policy gates and externally observable behavior.

## Scope
- Keep `src/goals/library/UMASuccessAssertions.sol` focused on UMA assertion data validation helpers.
- Add shared treasury plumbing helpers in `src/goals/library/TreasurySuccessAssertions.sol`:
  - pending assertion getters,
  - register prechecks + storage update,
  - clear/match helpers,
  - truthfulness requirement helper.
- Refactor `src/goals/GoalTreasury.sol` to call the shared treasury helper library for assertion mechanics.
- Refactor `src/goals/BudgetTreasury.sol` to call the same helper library.
- Preserve treasury-specific policy checks (`deadline`, `fundingDeadline`, `successResolutionDisabled`, resolver auth) in leaf contracts.

## Invariants to Preserve
- Only `successResolver` can register/clear success assertions.
- At most one success assertion can be pending at any time per treasury.
- Deadline/funding-window gating semantics remain unchanged for both treasuries.
- Budget `successResolutionDisabled` still gates register/resolve behavior.
- `resolveSuccess` still requires a pending assertion and validates the same UMA OOv3 fields.
- Finalization/disable paths still clear pending assertion state and emit equivalent events.

## Validation
- `pnpm -s verify:required`
- Completion workflow from `AGENTS.md`:
  - simplification pass (`agent-docs/prompts/simplify.md`),
  - test-coverage audit pass (`agent-docs/prompts/test-coverage-audit.md`),
  - completion audit pass (`agent-docs/prompts/task-finish-review.md`),
  - re-run `pnpm -s verify:required`.

# Goal

Reduce duplicated Goal-domain test deployment wiring by introducing a shared revnet harness deploy helper and routing integration tests through it.

# Scope

- Add shared helper in `test/goals/helpers/` for deploying `RevnetTestHarness` from build artifacts.
- Refactor:
  - `test/goals/GoalRevnetIntegration.t.sol`
  - `test/goals/RewardEscrowIntegration.t.sol`
- Keep behavior and assertions unchanged.

# Constraints

- Do not modify `lib/**`.
- Keep refactor test-only.
- Preserve deterministic deployment ordering assumptions used by predicted addresses in integration setup.

# Acceptance criteria

- No duplicated `_deployRevnetHarness` implementations remain in goal integration tests.
- Both integration suites deploy revnet harness through the shared helper.
- `forge build -q` passes.
- `pnpm -s test:lite` passes.

# Progress log

- 2026-02-19: Confirmed duplicated revnet harness deployment logic in goal integration tests.
- 2026-02-19: Added `test/goals/helpers/RevnetHarnessDeployer.sol` with shared interface + deploy helper.
- 2026-02-19: Refactored `GoalRevnetIntegration` and `RewardEscrowIntegration` tests to use the helper.
- 2026-02-19: Verification passed (`forge build -q`, `pnpm -s test:lite`).

# Open risks

- `RESOLVED (2026-02-19)`: helper now deploys `RevnetTestHarness` directly and no longer depends on build artifacts.

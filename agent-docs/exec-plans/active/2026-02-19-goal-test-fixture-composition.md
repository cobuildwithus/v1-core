# Goal

Centralize duplicated Goal integration-test setup into reusable fixture composition helpers while keeping tests on real deployed contracts (no replacement with mocks) and preserving behavior coverage.

# Scope

- Add shared fixture helper under `test/goals/helpers/` for:
  - revnet + goal treasury/vault/hook deployment wiring,
  - optional reward escrow composition,
  - split-context/controller-call helpers.
- Refactor:
  - `test/goals/GoalRevnetIntegration.t.sol`
  - `test/goals/RewardEscrowIntegration.t.sol`

# Constraints

- Do not modify `lib/**`.
- Keep tests integration-oriented with actual protocol contracts (`GoalTreasury`, `GoalStakeVault`, `GoalRevnetSplitHook`, `RewardEscrow`) rather than replacing with mocks.
- Preserve deterministic create-order assumptions for predicted treasury/hook addresses.

# Acceptance criteria

- Shared fixture helper owns common deployment/setup wiring used by both goal integration suites.
- Duplicated setup/context helpers are removed from individual suites.
- Test assertions remain intact (or are strictly equivalent).
- `forge build -q` passes.
- `pnpm -s test:lite` passes.

# Progress log

- 2026-02-19: Plan opened and target duplication points identified in both goal integration suites.
- 2026-02-19: Added `GoalRevnetFixtureBase` to centralize revnet + vault/treasury/hook setup, optional reward escrow wiring, shared split-context creation, and controller-call helper.
- 2026-02-19: Refactored `GoalRevnetIntegration` and `RewardEscrowIntegration` to consume shared fixture composition and removed duplicated local setup/context code.
- 2026-02-19: Further centralized common integration actions into fixture base (`_stakeGoal`, `_stakeCobuild`, `_fundViaHookUnderlying`, `_activateWithIncomingFlowAndHookFunding`) and removed per-suite duplicates.
- 2026-02-19: Added named `GoalIntegrationConfig` presets (`_goalConfigPresetNoEscrow`, `_goalConfigPresetWithEscrow`) and replaced inline config literals in both suites.
- 2026-02-19: Verification passed (`forge build -q`, `pnpm -s test:lite`).

# Open risks

- Any mismatch in predicted `computeCreateAddress` offsets can break constructor-time address checks.

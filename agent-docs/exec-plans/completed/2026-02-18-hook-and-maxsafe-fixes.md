# Goal
Ship two safety fixes: (1) make `GoalRevnetSplitHook` compatible with JB v5 payout-hook ERC20 allowance flow, and (2) make `GoalTreasury` treat `maxSafeRate == 0` as a real cap.

# Scope
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/goals/GoalTreasury.sol`
- `test/goals/GoalRevnetIntegration.t.sol`
- `test/goals/GoalTreasury.t.sol`

# Constraints
- Do not modify `lib/**`.
- Preserve existing native-token behavior unless required for safety.
- Keep hook behavior explicit and fail-safe for partial/zero pull outcomes.

# Acceptance criteria
- Hook no longer relies on `balanceOf(address(this))` for terminal ERC20 payouts; it pulls from caller via allowance and forwards expected amount paths.
- Hook tests cover terminal-allowance path and reject insufficient allowance/balance situations.
- Treasury sync applies zero max-safe cap (`maxSafeRate == 0`) instead of bypassing cap.
- Treasury tests assert zero-cap behavior.
- `forge build -q` and `pnpm -s test:lite` pass.

# Progress log
- 2026-02-18: Created plan and validated baseline codepaths and tests for both issues.
- 2026-02-18: Updated `GoalRevnetSplitHook` ERC20 paths to pull via caller allowance when available, fallback to prefunded hook balance, and enforce exact super-token amount forwarding.
- 2026-02-18: Tightened `GoalRevnetSplitHook` for reserved-token split mode (`groupId == 1`, controller-only caller, no terminal payout path), consuming hook-held balances and forwarding converted super tokens to flow.
- 2026-02-18: Updated `GoalTreasury._syncFlowRate` to always cap against `getMaxSafeFlowRate` and defensively floor negative max-safe values to zero.
- 2026-02-18: Added/updated regression tests in `test/goals/GoalRevnetIntegration.t.sol` and `test/goals/GoalTreasury.t.sol`.
- 2026-02-18: Verification passed with `forge build -q` and `pnpm -s test:lite`.
- 2026-02-18: Updated `GoalStakeVault` to accept explicit `paymentTokenDecimals` for conversion ratio, added constructor bounds check, and removed duplicate ruleset read in `depositGoal`.
- 2026-02-18: Renamed GoalTreasury funding window surface from `fundingDeadline` to `minRaiseDeadline` (interface, implementation, tests) to match intent.
- 2026-02-18: Added stake-vault regression tests for explicit decimal ratio behavior and invalid decimal bounds.
- 2026-02-18: Re-ran verification after rename/ratio changes (`forge build -q`, `pnpm -s test:lite`) with all suites passing.
- 2026-02-19: Added deep branch-coverage tests for `GoalRevnetSplitHook` (new unit suite), `GoalStakeVault`, and `GoalTreasury`, including constructor guards, state-machine edge paths, transfer mismatch paths, and token conversion mismatch paths.
- 2026-02-19: Regenerated goal-focused LCOV (`coverage/lcov-goals.info`): `GoalRevnetSplitHook` 100/100/100, `GoalStakeVault` 100/100/96.7, `GoalTreasury` 94.4/100/84.1 (remaining treasury misses are internal/unreachable guard branches under current public API).
- 2026-02-19: Full verification passed again with `forge build -q` and `pnpm -s test:lite` (482 tests passed, 0 failed).

# Open risks
- Controller-caller compatibility for reserved-token split contexts may need follow-up policy decisions.
- Existing tests that pre-mint hook balances may need to be reshaped to avoid masking allowance-based semantics.

# Budget Removal Force-Zero Terminalization

## Objective
- Ensure accepted budget removals immediately stop child budget outflow.
- Ensure removal/retry terminalization does not call non-terminal `sync()` paths.
- Preserve permissionless retry behavior without introducing keeper incentives in this patch.

## Scope
- `src/interfaces/IBudgetTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/tcr/BudgetTCR.sol`
- `test/BudgetTCR.t.sol`
- `agent-docs/references/tcr-and-arbitration-map.md`

## Plan
1. Add an owner-only budget-treasury entrypoint to force flow rate to zero without changing budget state.
2. Invoke that entrypoint in `BudgetTCR` removal/retry terminalization helper before terminal checks.
3. Remove `sync()` from removal/retry helper to avoid Funding->Active transitions during terminalization.
4. Add/adjust tests to assert immediate zeroing + no activation side effects during removal/retry.
5. Run required verification suite.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

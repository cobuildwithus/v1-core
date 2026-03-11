# Goal

Hard-cut treasury spend policy behavior to explicit `LinearSpendPolicy` configuration only, so goals and budgets no longer rely on legacy zero-policy branches and the repo no longer ships `UnitsCapSpendPolicy`.

# Scope

- `src/interfaces/ISpendPolicy.sol`
- `src/goals/policies/LinearSpendPolicy.sol`
- `src/goals/policies/UnitsCapSpendPolicy.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/tcr/library/BudgetTCRStackDeploymentLib.sol`
- Targeted tests under `test/goals/**` and `test/invariant/**`
- Matching docs in `agent-docs/**` and `ARCHITECTURE.md`

# Constraints

- Hard cutover only: no zero-policy compatibility shims.
- Preserve current goal behavior, current budget behavior, and capped-goal behavior via `LinearSpendPolicy` config.
- Keep budget policy wiring BudgetTCR-wide by default rather than per listing.
- Do not touch unrelated active TCR event work.
- Run required Solidity verification, completion workflow passes, and commit in the same turn.

# Acceptance Criteria

- `UnitsCapSpendPolicy` is removed from runtime/tests/docs.
- `ISpendPolicy.SpendContext` no longer carries recipient-unit state.
- `LinearSpendPolicy` supports uncapped and capped linear targeting with optional incoming-rate inclusion.
- `BudgetTreasury` requires nonzero `spendPolicy` and has no `address(0)` target/sync fallback path.
- Budget stack deployment wires an explicit default linear policy that reproduces current budget targeting semantics.
- Goal and budget tests cover the new policy configurations and no tests rely on the removed units-cap policy.

# Progress Log

- 2026-03-10: Confirmed current budget runtime behavior is still the legacy `incoming + balance / timeRemaining` branch because `BudgetTCRStackDeploymentLib` initializes budgets with `spendPolicy: address(0)`.
- 2026-03-10: Confirmed goal runtime is already policy-only, while several docs still describe a stale goal zero-policy fallback.
- 2026-03-10: Hard-cut budgets to required explicit spend policies, removed `UnitsCapSpendPolicy`, removed `SpendContext.totalRecipientUnits`, and extended `LinearSpendPolicy` with optional `maxTargetFlowRate`.
- 2026-03-10: Threaded a BudgetTCR-wide default budget spend policy through deployment/config plumbing and updated goal/budget docs/tests to reflect policy-only runtime behavior.
- 2026-03-10: Added regression coverage for zero-unit budget policy behavior, BudgetTCR budget-policy inheritance/validation, GoalFactory forwarding of budget spend policy, and BudgetTCR zero-context policy validation parity with `BudgetTreasury.initialize`.
- 2026-03-10: Completion workflow passes run: simplify completed, coverage audit applied additional tests, and final review found/fixed BudgetTCR zero-context validation drift plus one stale architecture doc line.
- 2026-03-10: Verification status: `pnpm -s lint:solidity:warnings` passed after a clean rebuild; `pnpm -s verify:required` now fails only in unrelated active TeamFlow work (`test/teamflow/TeamFlowFactory.t.sol`), outside this change set.

# Open Risks

- Budget policy hard cutover changes initializer requirements and deployment wiring across all real/test budget stacks in one pass.
- The shared worktree still has an unrelated failing required-lane TeamFlow test, so final repo-wide required verification is not green even though the spend-policy surface and lint baseline were revalidated.

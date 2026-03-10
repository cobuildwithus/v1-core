# Goal

Integrate the provided spend-policy patch so goal and budget treasuries can optionally delegate target flow-rate computation and sync mode to pluggable policy contracts, while preserving current behavior when no policy is configured.

## Scope

- `src/interfaces/ISpendPolicy.sol`
- `src/interfaces/IGoalTreasury.sol`
- `src/interfaces/IBudgetTreasury.sol`
- `src/goals/policies/LinearSpendPolicy.sol`
- `src/goals/policies/UnitsCapSpendPolicy.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/library/GoalFactoryCoreStackDeploy.sol`
- `src/tcr/library/BudgetTCRStackDeploymentLib.sol`
- All affected `GoalConfig` / `BudgetConfig` struct initializers in `src/**` and `test/**`
- Matching `agent-docs/**` updates

## Constraints

- No `lib/**` edits.
- Preserve legacy treasury behavior when `spendPolicy == address(0)`.
- Keep role/funds/lifecycle semantics unchanged outside target-rate computation and sync-mode selection.
- Do not revert unrelated dirty worktree changes.
- Run required Solidity verification and completion workflow before handoff.

## Acceptance Criteria

- Goal and budget treasuries expose optional `spendPolicy` config/getters and validate nonzero policy code at init time.
- New policy contracts compile and cover linear spenddown and units-capped behavior.
- Treasury target-rate logic uses legacy math when `spendPolicy == address(0)` and delegated policy context when configured.
- Goal sync can choose capped vs linear-fallback application based on policy sync mode; budget sync can do the same while defaulting to current capped behavior.
- Deployment helpers and every struct initializer compile by explicitly setting `spendPolicy`.
- Tests cover policy units/overflow edges plus treasury legacy-vs-policy integration behavior.

## Progress Log

- 2026-03-10: Loaded required architecture/security/process docs and claimed scope in coordination ledger.
- 2026-03-10: Confirmed the supplied zip bundle contents and mapped the repo-local diffs needed for compile/test call sites.
- 2026-03-10: Added pluggable spend-policy interfaces/contracts, treasury config wiring, and legacy-preserving deployment defaults.
- 2026-03-10: Added policy unit tests plus goal/budget integration coverage, including a fail-closed-at-deadline regression for policy-enabled goals.
- 2026-03-10: Verified with focused Forge tests, `pnpm -s verify:required`, and `pnpm -s lint:solidity:warnings`.
- 2026-03-10: Hardened treasury init-time policy validation after completion audit feedback so non-conforming codeful addresses fail fast instead of bricking later syncs.

## Open Risks

- Legacy deployment helpers still pass `spendPolicy: address(0)` until policy clones are explicitly wired into deployment flows.
- Units-based throttling depends on the treasury flow pool's direct recipient units; attaching the policy to the wrong treasury level will scale against the wrong weights.
Status: completed
Updated: 2026-03-09
Completed: 2026-03-09

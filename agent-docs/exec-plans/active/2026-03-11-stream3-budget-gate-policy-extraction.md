# 2026-03-11 Stream 3 Budget Gate Policy Extraction

## Goal

Separate budget routing/sync ownership from budget enablement gating by moving stake-backed credit-cap behavior behind a reusable `IBudgetGatePolicy` seam and adding a managed-style no-op policy.

## Constraints

- Preserve current open-goal routing and stake-backed enable/disable behavior exactly.
- Keep controller-owned sync events/failure reporting observable from the controller path.
- Do not add managed/open runtime flags inside policy contracts.
- Keep policy contracts stateless unless a concrete integration forces storage.
- Prefer a shared helper that future controllers can reuse instead of a `BudgetTCR`-only hook.

## Files / Ownership

- `src/interfaces/IBudgetGatePolicy.sol`
- `src/goals/policies/StakeCoverageGatePolicy.sol`
- `src/goals/policies/NoopBudgetGatePolicy.sol`
- `src/goals/policies/library/BudgetGatePolicyHook.sol`
- `src/tcr/BudgetTCR.sol`
- `src/tcr/interfaces/IBudgetTCR.sol`
- `src/tcr/storage/BudgetTCRStorageV1.sol`
- `src/tcr/library/BudgetTCRCreditCapActions.sol`
- `test/BudgetTCRCreditLineGating.t.sol`
- `test/tcr/BudgetTCRRunwayCapEnforcement.t.sol`
- Additional targeted policy-hook tests if needed

## Intended Shape

- `IBudgetGatePolicy` accepts a controller-neutral sync context and returns:
  - whether recipient enablement should be updated
  - the desired enabled state
  - zero or more call-failure notices for controller-side emission
- `BudgetGatePolicyHook` wraps the policy call so any controller can normalize policy-call failure into the same result shape.
- `StakeCoverageGatePolicy` owns the current stake-backed insured-line plus runway-cap decision logic.
- `NoopBudgetGatePolicy` always leaves recipient enablement untouched.
- `BudgetTCR.syncBudgetTreasuries` calls the hook, emits failures from the controller, applies the recipient toggle if requested, then continues treasury sync.

## Verification Target

- Open-goal sync still gates recipient enablement on stake-backed coverage and runway cap.
- A no-op policy leaves active budgets enabled regardless of underwriter coverage.
- The shared helper is reusable without `BudgetTCR`-specific storage assumptions.

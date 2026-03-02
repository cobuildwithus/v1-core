# Budget removal cutover: stop flow without auto-slash

Status: active
Created: 2026-03-01
Updated: 2026-03-02

## Goal

- Hard-cut removal semantics so accepted BudgetTCR removals stop funding/outflow without automatically forcing slashable
  budget failure for activated budgets.

## Success criteria

- Activated budget removal finalization no longer forces `disableSuccessResolution()` and no longer forces
  `resolveFailure()`.
- Activated budget removal still removes parent/ledger routing and enforces zero outflow.
- Pre-activation removal remains immediate auto-terminalized (`Failed`) and remains non-slashable because
  `activatedAt == 0`.
- Retry path supports liveness progression for removed activated budgets without forcing failure.
- Solidity required gate (`pnpm -s verify:required`) passes.

## Scope

- In scope:
  - `src/tcr/BudgetTCR.sol` removal finalization/retry branching semantics.
  - `src/tcr/storage/BudgetTCRStorageV1.sol` only if snapshot data is required for activation-at-removal branching.
  - `test/BudgetTCR.t.sol` behavioral updates and regressions.
  - Architecture/spec docs reflecting final removal semantics.
- Out of scope:
  - Any `lib/**` changes.
  - New backward-compatibility paths or migration scaffolding.
  - Release/publish flows.

## Constraints

- Technical constraints:
  - Keep canonical typed interface interactions (`IBudgetTreasury`), no low-level selector calls.
  - Maintain fail-closed spend-stop behavior for removal finalization (`forceFlowRateToZero`).
  - Preserve append-only registered budget accounting semantics.
- Product/process constraints:
  - Hard cutover only (no legacy semantics retained).
  - Keep protocol incentives simple: removal is operational stop, slash only on true terminal outcomes.

## Risks and mitigations

1. Risk: Activation timing race could misclassify removal branch.
   Mitigation: pre-activation accepted removals disable success resolution, and `BudgetTreasury.sync()` fail-closes funding state to `Failed` when success resolution is disabled.
2. Risk: Removed activated budgets remain unresolved too long and block caller withdrawal prep.
   Mitigation: Retry path enforces zero outflow and attempts treasury progression via permissionless retry.
3. Risk: Doc drift with lifecycle specs.
   Mitigation: Update architecture/spec maps in same change set.

## Tasks

1. Implement removal-branch logic in `BudgetTCR` for pre-activation strict-fail vs activated no-auto-fail.
2. Update retry behavior for removed activated budgets to progress via sync without forced failure.
3. Update and extend BudgetTCR removal tests.
4. Update architecture/spec docs for new semantics.
5. Run required verification and completion workflow passes.

## Decisions

- Pre-activation accepted removals will auto-terminalize to `Failed` immediately (non-slashable due to
  `activatedAt == 0`).
- Activated accepted removals stop inflow/outflow operationally but do not auto-fail/auto-disable success resolution.
- Do not add acceptance-timestamp storage snapshots for removal classification; rely on activation state plus funding-state fail-closed sync semantics.

## Verification

- Commands to run:
  - `pnpm -s verify:required`
- Expected outcomes:
  - Required checks pass with updated removal semantics and tests.

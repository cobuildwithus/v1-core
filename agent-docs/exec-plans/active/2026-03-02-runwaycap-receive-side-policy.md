## Goal

Apply runway-cap policy cutover so `runwayCap` gates protocol-routed goal-flow inflow at `BudgetTCR` recipient enablement, not discretionary donations at `BudgetTreasury`.

## Scope

- `src/goals/BudgetTreasury.sol`
- `src/tcr/BudgetTCR.sol`
- `test/tcr/BudgetTCRRunwayCapEnforcement.t.sol`
- `test/goals/BudgetTreasuryRunwayCapDonation.t.sol`
- `test/goals/BudgetTreasury.t.sol`
- `test/BudgetTCRCreditLineGating.t.sol`

## Constraints

- No `lib/**` edits.
- Preserve best-effort/non-bricking behavior in budget-sync enforcement.
- Do not revert unrelated dirty worktree changes.
- Run required Solidity verification gate before handoff.
- Run completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`.

## Acceptance criteria

- `BudgetTreasury.canAcceptFunding()` no longer checks treasury balance against `runwayCap`.
- `BudgetTCR` enforcement applies `effectiveCap = min(runwayCap, creditLine)` when both nonzero and disables when `received >= effectiveCap`.
- `lambda == 0` path still enforces runway cap when configured.
- New tests cover runway/credit boundary combinations and donations allowed beyond runway cap.
- `pnpm -s verify:required` passes after final changes.

## Progress log

- 2026-03-02: Claimed scope in coordination ledger and started implementation from provided patch archive.
- 2026-03-02: Ran completion workflow passes (`simplify`, `test-coverage-audit`, `task-finish-review`).
- 2026-03-02: `verify:required` failed on stale lambda-zero expectation in `BudgetTCRCreditLineGating`; updating integration test to policy cutover semantics.

## Open risks

- Shared worktree contains unrelated active edits in overlapping files; merge must avoid regressions.
- Best-effort gating depends on sync-call frequency, not immediate on-chain push.

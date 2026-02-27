# Window-Normalized Budget Points

Status: active
Created: 2026-02-27
Updated: 2026-02-27

## Goal

Switch reward scoring from raw matured stake-time to window-normalized matured support (`average matured support over scoring window`), and derive budget maturation from scoring-window length (bounded fraction) instead of `executionDuration`.

## Acceptance criteria

- Budget/user/successful-point outputs used by reward distribution are window-normalized.
- Budget registration stores a scoring-window start timestamp and computes maturation from window length with bounded clamp.
- `executionDuration` no longer drives maturation economics.
- Success-finalization snapshots and claim preparation use the normalized semantics consistently.
- Tests are updated to assert normalized behavior and preserve payout/accounting invariants.
- Required verification for Solidity edits passes: `pnpm -s verify:required`.

## Scope

- In scope:
  - `src/goals/BudgetStakeLedger.sol`
  - `src/interfaces/IBudgetStakeLedger.sol`
  - reward/ledger tests under `test/goals/**` and relevant invariants
  - docs touching reward-point semantics in `agent-docs/**`
- Out of scope:
  - `lib/**`
  - changing reward escrow payout math shape (`pro-rata by points` remains)
  - adding backward-compat shims for old point semantics

## Constraints

- Keep checkpoint path deterministic and sorted-merge behavior unchanged.
- Preserve fail-closed budget registration validation.
- Keep change set simple: retain raw accrual internals where possible, normalize at scoring outputs/snapshots.

## Decisions

- Scoring window start is anchored at ledger budget registration time (`scoringStartsAt`), clamped to `scoringEndsAt` when the budget funding deadline is already in the past.
- Maturation derives from registered window length with clamp:
  - `tau = clamp(window / 10, 1 second, 30 days)`.
- Normalized points use integer division of raw points by window seconds (no extra scaling constant).

## Risks

1. Behavioral changes in tests that assumed monotonic cumulative raw points.
   - Mitigation: rewrite assertions around normalized invariants and payout proportionality.
2. Rounding drift (sum user normalized points vs normalized budget points).
   - Mitigation: keep approximate-equality tests where appropriate.
3. Docs drift with prior raw stake-time language.
   - Mitigation: update architecture/spec/reference docs in same change set.

## Tasks

1. Patch ledger interface/storage/helpers for window-start metadata, normalized outputs, and window-derived maturation.
2. Update finalization and claim-prep point aggregation to normalized semantics.
3. Update high-signal tests (`BudgetStakeLedgerEconomics`, `RewardEscrow`, dust/invariant paths) for new semantics.
4. Update docs that define point meaning and maturation source.
5. Run required verification and fix regressions.

## Progress log

- 2026-02-27: Read architecture/spec/reliability/security docs and current ledger/reward/test call paths.
- 2026-02-27: Implemented normalized scoring outputs/snapshots and scoring-window-derived maturation in `BudgetStakeLedger`; exposed `scoringStartsAt` in `IBudgetStakeLedger.BudgetInfoView`.
- 2026-02-27: Updated reward/ledger tests for normalized semantics and rounding behavior; fixed invalid-budget view regressions to return zero for unknown budgets.
- 2026-02-27: Updated architecture/spec/reference docs to describe normalized points and window-derived warmup.

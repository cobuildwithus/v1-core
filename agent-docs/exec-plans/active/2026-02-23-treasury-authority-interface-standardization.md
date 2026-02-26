# Standardize Treasury Authority Interface

Status: in_progress
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Replace dynamic treasury auth probing (`controller()`/`owner()` selector fallback) with a single canonical treasury authority surface (`authority()`) so `GoalStakeVault` resolves control deterministically.

## Scope

- In scope:
  - Add a new canonical interface `ITreasuryAuthority` with `authority() -> address`.
  - Implement `authority()` in concrete treasury contracts (`GoalTreasury`, `BudgetTreasury`).
  - Refactor `GoalStakeVault` to resolve one-hop forwarders once and then call `authority()` only.
  - Update affected tests/mocks and architecture docs for this breaking interface shift.
- Out of scope:
  - Any changes under `lib/**`.
  - Lifecycle or economic-policy changes unrelated to treasury authority resolution.

## Constraints

- Preserve existing stake vault goal-resolution and slasher-gating behavior except for intended interface-surface simplification.
- Keep forwarder resolution as one-hop via `TreasuryResolver`.
- Verification required:
  - `forge build -q`
  - `pnpm -s test:lite:shared`

## Acceptance criteria

- `GoalStakeVault` no longer probes `controller()` or `owner()` directly.
- Treasury authority reads use only `ITreasuryAuthority.authority()` against the resolved effective treasury.
- `GoalTreasury` and `BudgetTreasury` expose `authority()` with deterministic semantics.
- Existing tests are updated to the new canonical authority interface and pass.

## Progress log

- 2026-02-23: Drafted plan and mapped current `GoalStakeVault` auth heuristics + test fixtures.
- 2026-02-23: Added `ITreasuryAuthority` and moved `IGoalTreasury`/`IBudgetTreasury` onto the canonical authority surface.
- 2026-02-23: Refactored `GoalStakeVault` authority resolution to one-hop forwarder resolve + `authority()` call only; removed `controller()`/`owner()` probing path.
- 2026-02-23: Implemented concrete `authority()` getters in `GoalTreasury` (`address(this)`) and `BudgetTreasury` (`controller`), removed `ITreasuryController`, and updated vault tests/mocks/docs accordingly.
- 2026-02-23: Completion audit run via fresh subagent; no remaining high/medium findings in scoped change.
- 2026-02-23: Full Foundry gate execution delegated to another active agent per user instruction.

## Open risks

- This is a breaking external interface change for integrators currently depending on legacy `controller()`/`owner()` probe compatibility.

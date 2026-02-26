# Proposal 6: Thin TreasuryBase extraction

Status: completed
Created: 2026-02-20
Updated: 2026-02-20

## Goal

Extract a thin shared treasury base for truly identical mechanics between `GoalTreasury` and `BudgetTreasury` without changing external interfaces or lifecycle semantics.

## Success criteria

- `GoalTreasury` and `BudgetTreasury` inherit a new `TreasuryBase`.
- Shared donation ingress wrappers are centralized and hook-driven.
- Shared `treasuryBalance` and internal force-zero flow helper are centralized.
- Existing externally visible errors/events/state transitions remain unchanged.
- Verification passes:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - Add `src/goals/TreasuryBase.sol` abstract contract.
  - Move common donation ingress wrappers into base with override hooks for policy/events.
  - Move common `treasuryBalance` and internal flow-zero helper into base.
  - Refactor `GoalTreasury` + `BudgetTreasury` to wire hooks and use base.
  - Update architecture/module docs for new goals-domain boundary artifact.
- Out of scope:
  - Unifying goal/budget state machines.
  - Unifying residual settlement/event schemas.
  - Changing external interfaces under `src/interfaces/**`.

## Constraints

- Technical constraints:
  - Preserve goal vs budget economics (`targetFlowRate`, activation, finalization semantics).
  - Preserve error selectors and emitted event payloads.
  - Do not modify `lib/**`.
- Product/process constraints:
  - Keep refactor narrow and reviewable.
  - Follow AGENTS verification baseline before handoff.

## Risks and mitigations

1. Risk: Hook abstraction could alter revert surface for donation state gating.
   Mitigation: Use per-contract `_revertInvalidState()` hooks that revert existing interface errors.
2. Risk: Shared helper could accidentally alter finalize-side flow-zero behavior.
   Mitigation: Reuse helper only where existing logic is identical (`if totalFlowRate != 0 then set 0`).
3. Risk: Inheritance changes can unintentionally alter storage layout assumptions.
   Mitigation: Contracts are non-upgradeable; keep variable declarations in concrete treasuries except shared logic requiring no new mutable state.

## Tasks

1. Create `TreasuryBase` with hook-based donation ingress wrappers.
2. Add shared `treasuryBalance` and `_forceFlowRateToZero` helpers in base.
3. Refactor `GoalTreasury` to inherit base and wire `_canAcceptDonation` + `_afterDonation` + `_revertInvalidState`.
4. Refactor `BudgetTreasury` similarly and delete duplicated donation/treasuryBalance/force-zero code.
5. Update architecture docs referencing goals/treasury domain composition.
6. Run required build/tests and capture outcomes.

## Decisions

- Keep base thin and mechanics-focused; do not unify policy-heavy lifecycle logic.

## Verification

- Commands to run:
  - `forge build -q`
  - `pnpm -s test:lite`
- Expected outcomes:
  - Build succeeds.
  - Lite suite succeeds with no regressions in goal/budget treasury tests.
Completed: 2026-02-20

# UMA Success Assertion Base Extract

Status: active
Created: 2026-02-21
Updated: 2026-02-21

## Goal

- Extract duplicated UMA success-assertion plumbing from `GoalTreasury` and `BudgetTreasury` into one shared base contract while preserving external behavior and interfaces.

## Success criteria

- `GoalTreasury` and `BudgetTreasury` no longer duplicate pending-assertion state storage and UMA assertion validation logic.
- Shared base owns:
  - pending assertion state,
  - `registerSuccessAssertion`,
  - `clearSuccessAssertion`,
  - `_requireTruthfulSuccessAssertion`.
- Derived treasuries retain treasury-specific assertion window/state-machine rules.
- Existing build + lite suite pass:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - Add shared UMA assertion base contract under `src/goals/`.
  - Refactor `src/goals/GoalTreasury.sol` to inherit and implement hooks.
  - Refactor `src/goals/BudgetTreasury.sol` to inherit and implement hooks.
- Out of scope:
  - Goal/budget lifecycle policy changes.
  - BudgetTCR orchestration changes.
  - Interface shape changes under `src/interfaces/**`.

## Constraints

- Technical constraints:
  - Preserve current error/event surface at external entry points.
  - Preserve Policy C semantics and pending-assertion race guards.
  - Keep resolver-gated success flow unchanged.
- Product/process constraints:
  - Keep diff narrow and auditable.
  - Run required verification before handoff.

## Risks and mitigations

1. Risk: changing inheritance introduces subtle override/resolution issues.
   Mitigation: keep shared base narrowly scoped and compile-check first before running full tests.
2. Risk: assertion gate behavior drifts between treasuries.
   Mitigation: enforce treasury-specific rules via explicit hook overrides and keep existing tests unchanged.
3. Risk: event/error emission changes unintentionally.
   Mitigation: use derived hooks to emit/revert existing interface events/errors.

## Tasks

1. Add shared base contract for pending assertion state and UMA assertion verification.
2. Refactor `GoalTreasury` to consume base and remove duplicated assertion internals.
3. Refactor `BudgetTreasury` to consume base and remove duplicated assertion internals.
4. Run `forge build -q`.
5. Run `pnpm -s test:lite`.

## Decisions

- Keep treasury-specific assertion registration gates in derived contracts via base hooks.
- Preserve external function signatures (`registerSuccessAssertion`, `clearSuccessAssertion`, `resolveSuccess`) and resolver model.

## Progress log

- 2026-02-21: Added `src/goals/UMASuccessAssertionTreasuryBase.sol` and moved shared pending-assertion state plus UMA assertion verification there.
- 2026-02-21: Refactored `src/goals/GoalTreasury.sol` to inherit the shared base and provide goal-specific assertion gate/window hooks.
- 2026-02-21: Refactored `src/goals/BudgetTreasury.sol` to inherit the shared base and provide budget-specific assertion gate/window hooks (including `successResolutionDisabled` behavior).
- 2026-02-21: Verification status:
  - `forge build -q`: failed due unrelated pre-existing interface/implementation drift in current workspace (for example missing `lifecycleStatus` in `GoalTreasury`/`BudgetTreasury`, plus missing view methods in `BudgetStakeLedger` and `RewardEscrow`).
  - `pnpm -s test:lite`: failed for the same unrelated compile blocker.
  - Scoped compile for refactor targets passed:
    - `forge build -q src/goals/UMASuccessAssertionTreasuryBase.sol src/goals/GoalTreasury.sol src/goals/BudgetTreasury.sol src/goals/UMATreasurySuccessResolver.sol`

## Verification

- Commands to run:
  - `forge build -q`
  - `pnpm -s test:lite`
- Expected outcomes:
  - Compilation succeeds.
  - Lite suite passes with no goal/budget treasury regressions.

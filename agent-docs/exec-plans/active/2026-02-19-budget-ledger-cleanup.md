# Budget Ledger Cleanup And Consistency

Status: active
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Simplify and standardize budget-ledger-adjacent safety fixes while preserving the hard failure-mode protections:
  - no revert when a `BudgetStakeStrategy` treasury address is predicted/not deployed,
  - no silent nested control-flow in budget terminalization retries,
  - no regression in allocation-ledger checkpoint safety checks.

## Acceptance criteria

- `BudgetStakeStrategy` uses a non-reverting resolved-read pattern consistent with stake-vault/treasury safe-read style.
- `BudgetTCR._tryResolveBudgetTerminalState` keeps the same retry sequence (`resolveFailure` -> `markExpired` -> `sync`) with clearer linear control flow.
- Existing checkpoint safety behavior in `CustomFlow` remains intact (single-strategy + weight consistency guard).
- Targeted and baseline verification pass:
  - `forge build -q`
  - `pnpm -s test:lite`

## Scope

- In scope:
  - `src/allocation-strategies/BudgetStakeStrategy.sol`
  - `src/tcr/BudgetTCR.sol`
  - `test/goals/BudgetStakeStrategy.t.sol` (if needed for coverage of new read style)
- Out of scope:
  - Changes to `lib/**`.
  - Redesigning allocation-ledger architecture or strategy registration model.
  - Broad reward-accounting model changes beyond this cleanup.

## Constraints

- Technical constraints:
  - Preserve current interface/event/error surface unless simplification clearly remains backward compatible.
  - Keep behavior fail-safe for undeployed/miswired external addresses.
- Product/process constraints:
  - Must follow repo hard rules and doc routing.
  - Must run Solidity verification baseline before handoff.

## Open risks

1. Risk: Over-simplifying ledger checkpointing could weaken the weight-source mismatch guard.
   Mitigation: Keep existing mismatch guard unless a stricter equivalent is introduced.
2. Risk: Refactor of terminal retry helper could accidentally alter side-effect ordering.
   Mitigation: Preserve exact call order and post-attempt resolved checks.

## Tasks

1. Update `BudgetStakeStrategy` resolved-check helper to `code.length` guard plus typed `resolved()` read with graceful fallback.
2. Flatten `BudgetTCR._tryResolveBudgetTerminalState` into linear retries with early exits.
3. Add/adjust focused tests for undeployed treasury behavior in budget stake strategy.
4. Run build + regression suite and capture outcomes.

## Decisions

- Keep `CustomFlow` checkpoint weight-mismatch guard unchanged for now; it remains the explicit protection against allocation/checkpoint source divergence.

## Progress log

- 2026-02-19: Read required architecture/reliability/security docs and validated requested cleanup candidates.
- 2026-02-19: Opened plan and confirmed target files/tests.
- 2026-02-19: Implemented `BudgetStakeStrategy` helper using `code.length` guard + typed `try/catch` read after removing low-level staticcall variant.
- 2026-02-19: Simplified `BudgetTCR` terminal-state retry helper to linear attempts with identical call ordering.
- 2026-02-19: Added undeployed-treasury regression test in `test/goals/BudgetStakeStrategy.t.sol`.
- 2026-02-19: Verification passed (`forge build -q`, `pnpm -s test:lite`).

## Verification

- Commands to run:
  - `forge build -q`
  - `pnpm -s test:lite`
- Expected outcomes:
  - Compilation succeeds with no contract/interface errors.
  - Lite test suite passes with no regressions in goal/flow/tcr paths.

# Proposal 6 Hard Subsystem Invariants

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Close remaining invariant/property test gaps for hard subsystems by adding focused Foundry fuzz/invariant coverage for:
- allocation commitments and prev-weight cache behavior,
- ledger-mode checkpointing and budget-delta detection edge conditions,
- RewardEscrow per-account claim bounds,
- BudgetStakeLedger points monotonicity across stake changes.

## Scope

- In scope:
  - Extend existing flow property tests with cache migration assertions on sync/clear paths.
  - Extend ledger-mode property tests with unresolved/resolved checkpoint behavior and delta-edge scenarios.
  - Extend RewardEscrow invariant handler/tests with per-account cumulative claim accounting bounds.
  - Extend BudgetStakeLedger economics fuzz tests to cover monotonic points under stake increases/decreases/zeroing transitions.
- Out of scope:
  - Production logic changes under `src/**`.
  - Any change under `lib/**`.

## Constraints

- Preserve protocol behavior and current external interfaces.
- Reuse existing harnesses/mocks where possible.
- Verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- New tests compile and run in standard suites.
- Added assertions specifically cover the four Proposal 6 targets.
- No production contract behavior changes required.

## Progress Log

- 2026-02-21: Audited existing coverage with four subagent passes (flow commit/cache, ledger mode, escrow claim bounds, budget points monotonicity).
- 2026-02-21: Identified narrow gaps: per-account escrow claim bound invariant, stake-change monotonicity fuzz, and additional flow sync/ledger-mode edge assertions.
- 2026-02-21: Implemented targeted test additions in `test/flows/FlowAllocationsLifecycle.t.sol`, `test/flows/FlowLedgerChildSyncProperties.t.sol`, `test/flows/GoalFlowLedgerModeParity.t.sol`, `test/invariant/RewardEscrow.invariant.t.sol`, and `test/goals/BudgetStakeLedgerEconomics.t.sol`.
- 2026-02-21: Verification completed successfully:
  - `forge build -q`
  - `pnpm -s test:lite` (802 passed, 0 failed)

## Risks

- Existing workspace includes unrelated in-progress code changes; verification failures may be pre-existing and must be reported explicitly if encountered.

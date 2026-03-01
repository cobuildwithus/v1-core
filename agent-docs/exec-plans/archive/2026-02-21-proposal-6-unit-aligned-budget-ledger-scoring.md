# Proposal 6 Unit-Aligned Budget Ledger Scoring

Status: in_progress
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Align budget stake-time scoring with effective Flow influence so stake that rounds to zero distribution units cannot accrue reward points.

## Scope

- In scope:
  - Quantize BudgetStakeLedger checkpointed per-budget allocated stake using Flow's unit scale (`1e15`) before storing/accruing.
  - Apply the same quantized comparison in GoalFlowLedgerMode budget-delta detection.
  - Update tests covering delta detection and reward-point behavior in the dust window.
  - Update architecture/reference docs to reflect the new semantics.
- Out of scope:
  - Changes under `lib/**`.
  - Changing Flow core unit scale.

## Constraints

- Preserve existing external interfaces.
- Keep arithmetic deterministic and fail-closed.
- Verification before handoff:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance Criteria

- Budget stake points only accrue for quantized allocated stake that maps to non-zero effective Flow unit weight.
- Ledger-mode budget-delta detection no longer flags changes that are below effective unit resolution.
- Existing behavior remains stable outside quantization-edge cases.
- Docs clearly state that reward scoring tracks effective unit-scale stake.

## Progress Log

- 2026-02-21: Confirmed mismatch exists between Flow unit math (`/1e15`) and ledger scoring (`/1e6` only).
- 2026-02-21: Selected Option 1 implementation with user approval: scoring must match effective Flow influence.
- 2026-02-21: Implemented effective stake quantization in `BudgetStakeLedger.checkpointAllocation` (`Math.mulDiv(..., 1e6)` then floor to `1e15` scale) via `_effectiveAllocatedStake`.
- 2026-02-21: Implemented matching quantized delta detection in `GoalFlowLedgerMode._detectBudgetDeltaTreasuriesMemory` via `_effectiveAllocatedStake`.
- 2026-02-21: Updated tests for unit-scale semantics:
  - `test/goals/BudgetStakeLedgerEconomics.t.sol` dust-boundary points behavior.
  - `test/flows/GoalFlowLedgerModeParity.t.sol` high-weight delta + dust no-delta cases.
  - `test/goals/RewardEscrow.t.sol` scaled point expectations/tolerance.
  - `test/goals/RewardEscrowDustRetention.t.sol` scaled fixture weights.
  - `test/flows/FlowLedgerChildSyncProperties.t.sol` fuzz bounds for effective deltas + witness shape compatibility.
- 2026-02-21: Updated docs:
  - `ARCHITECTURE.md`
  - `agent-docs/cobuild-protocol-architecture.md`
  - `agent-docs/references/goal-funding-and-reward-map.md`
- 2026-02-21: Verification:
  - Passed: `forge test --match-path test/flows/FlowLedgerChildSyncProperties.t.sol`
  - Passed: `forge test --match-path test/goals/BudgetStakeLedgerEconomics.t.sol`
  - Passed: `forge test --match-path test/goals/RewardEscrow.t.sol`
  - Passed: `forge test --match-path test/goals/RewardEscrowDustRetention.t.sol`
  - Blocked (pre-existing workspace conflicts): `forge build -q`, `pnpm -s test:lite` fail in `src/goals/GoalTreasury.sol` due inheritance/override compile errors unrelated to this change.

## Risks

- Behavior changes for very small stake allocations near the unit quantization boundary can invalidate tests that assume raw-stake scoring.

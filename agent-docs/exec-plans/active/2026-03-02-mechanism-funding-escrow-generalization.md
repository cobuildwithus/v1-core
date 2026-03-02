# 2026-03-02 Mechanism Funding Escrow Generalization

## Goal
Implement the mechanism-agnostic funding escrow update in `AllocationMechanismTCR` so budget-flow capital is routed through escrow and governed by per-round min/max/deadline policy.

## Scope
- `src/tcr/AllocationMechanismTCR.sol`
- `src/escrow/MechanismFundingEscrow.sol`
- `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`

## Constraints
- Do not touch `lib/**`.
- Preserve TCR registration/removal lifecycle semantics.
- Keep funds-routing behavior explicit and typed.
- Run required Solidity verification before handoff.

## Plan
1. Apply escrow generalization and funding-policy lifecycle logic from provided changeset.
2. Run simplify pass and apply behavior-preserving cleanup only.
3. Run test-coverage-audit pass and add highest-impact tests if gaps are found.
4. Run final task-finish-review pass and resolve findings.
5. Run `pnpm -s verify:required` and commit touched files.

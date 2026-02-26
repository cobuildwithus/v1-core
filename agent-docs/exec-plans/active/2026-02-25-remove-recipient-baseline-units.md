# 2026-02-25 Remove Recipient Baseline Units

## Goal

Remove default recipient distribution bootstrap units so recipients receive no flow until explicit allocation, while preserving outflow liveness when total units cross zero.

## Scope

- `src/Flow.sol`
- `src/library/FlowAllocations.sol`
- `src/library/CustomFlowAllocationEngine.sol`
- `test/flows/**` affected by baseline assumption and refresh behavior

## Constraints

- Do not change role permissions for `refreshTargetOutflowRate`.
- Preserve distribution and manager-reward split math.
- Keep behavior deterministic for:
  - `0 -> >0` total units: start distribution flow when cached target outflow is non-zero.
  - `>0 -> 0` total units: stop distribution flow.

## Plan

1. Remove baseline member-unit assignment from recipient add paths.
2. Add allocation-path best-effort outflow refresh tied to total-units zero-crossings.
3. Update tests that currently encode baseline `10` assumptions.
4. Add/adjust tests for first-allocation bootstrap and deallocation-to-zero behavior.
5. Run required verification and completion workflow passes.

## Verification

- `pnpm -s verify:required`
- targeted `forge test` commands during iteration

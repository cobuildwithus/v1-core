# Event Signature Surface Adjustments

Status: in_progress
Created: 2026-02-25
Updated: 2026-02-25

## Goal

Implement the full event-surface adjustment plan focused on indexer completeness and ergonomics while prioritizing gas efficiency, then interface simplicity.

## Scope

- In scope:
  - Flow initialization and flow-rate event schema updates.
  - Allocation commit event-surface reduction to packed snapshot commit semantics.
  - Child-sync pipeline event context expansion for parent-join indexing.
  - Reward escrow claim-event consolidation.
  - Goal stake vault duplicate juror-delegate emission removal in opt-in path.
  - Budget stack deployment event ordering/discovery fixes.
  - Required interface, emit-site, and test updates.
- Out of scope:
  - `lib/**` changes.
  - Unrelated lifecycle or economic-policy changes.
  - Backward-compatibility shims for legacy event consumers.

## Constraints

- Preserve lifecycle monotonicity, role boundaries, and funds-routing invariants.
- Keep event changes deterministic and indexer-friendly with minimal redundant logs.
- Prefer lower log volume and fewer hot-path emits when behavior is equivalent.
- Run required Solidity verification gate before handoff.
- Run completion workflow subagent passes before final handoff.

## Acceptance Criteria

- Flow emits a canonical target-outflow-rate update event for all mutation paths, including direct setter path.
- Flow initialization events expose full role/config required for event-only reconstruction.
- Allocation commit emits one packed snapshot event and no longer requires per-recipient hot-path events.
- Pipeline child-sync events include enough parent context to join without tx-hash heuristics.
- Reward escrow claim path emits one consolidated claim event per call.
- Budget stack event stream supports same-tx discovery without missing critical init config.
- Tests cover schema and emit ordering/content changes for touched modules.

## Progress Log

- 2026-02-25: Created execution plan and coordination claim; pending parallel code mapping and implementation.

## Open Risks

- Existing dirty worktree includes in-flight edits in overlapping modules; changes must layer safely without reverting.
- Event signature changes may require broad test fixture and expectation updates across multiple domains.

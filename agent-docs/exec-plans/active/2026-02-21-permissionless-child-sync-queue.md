# Permissionless Child Sync Queue Processing

Status: complete
Created: 2026-02-21
Updated: 2026-02-21

## Goal

Make child flow-rate queue processing permissionless by loosening `Flow.workOnChildFlowsToUpdate(uint256)` authorization, while preserving bounded execution and deterministic queue semantics.

## Scope

- In scope:
  - Remove privileged role gating from `workOnChildFlowsToUpdate(uint256)`.
  - Keep existing bounded batch behavior (`MAX_CHILD_UPDATES_PER_TX`) and `nonReentrant`.
  - Add/update tests to prove unprivileged callers can process the queue with equivalent behavior to privileged callers.
  - Update architecture/reference docs for the new child-sync caller model.
- Out of scope:
  - Any change under `lib/**`.
  - Changes to flow-rate mutation permissions (`setFlowRate`, `increaseFlowRate`, `decreaseFlowRate`).
  - Behavioral changes to queue ordering or child-sync math.

## Constraints

- Child queue processing must remain deterministic, bounded, and state-derived.
- No caller incentives/payouts should be introduced.
- Required verification commands:
  - `forge build -q`
  - `pnpm -s test:lite`

## Acceptance criteria

1. `workOnChildFlowsToUpdate(uint256)` is callable by any address.
2. Existing bounded work limits still apply.
3. Tests confirm:
  - unprivileged caller can process queued child sync work;
  - resulting queue reduction/behavior matches privileged caller execution on equivalent setup.
4. Required verification commands pass.

## Progress log

- 2026-02-21: Reviewed architecture/security/reliability docs and flow child-sync implementation; confirmed library-level hard cap already enforces at-most-10 updates per call.
- 2026-02-21: Decided Option A (remove gating on existing entrypoint) is preferred over adding a second public entrypoint with another cap.
- 2026-02-21: Implemented Option A by removing `onlyOwnerOrParentOrManager` from `Flow.workOnChildFlowsToUpdate(uint256)` while preserving `nonReentrant`.
- 2026-02-21: Updated flow tests to confirm permissionless caller support and result parity with owner calls for equivalent queue state.
- 2026-02-21: Updated architecture/reference docs to record permissionless + bounded queue processing.
- 2026-02-21: Verification run:
  - `forge build -q` passed.
  - `pnpm -s test:lite` blocked by unrelated pre-existing syntax error in `src/library/GoalFlowLedgerMode.sol:278` (`Expected ',' but got identifier`).

## Open risks

- Public callers can trigger sync earlier than operators might prefer, but execution remains bounded and converges to protocol-derived state.
- Public callers can spend gas on repeated calls; this is caller-borne griefing and does not grant additional authority or payouts.

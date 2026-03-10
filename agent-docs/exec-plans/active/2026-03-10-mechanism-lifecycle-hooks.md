# Goal

Add generic allocation-mechanism lifecycle hook support in `AllocationMechanismTCR` so mechanism payouts can react to escrow releases and best-effort clean up on mechanism removal without touching the in-flight TeamFlow runtime refactor.

# Scope

- `src/tcr/AllocationMechanismTCR.sol`
- New `src/tcr/interfaces/IMechanismLifecycleHooks.sol`
- Targeted `test/rounds/AllocationMechanismTCR.t.sol`

# Constraints

- Do not modify `src/teamflow/**` or TeamFlow-owned docs/tests while the concrete runtime refactor is active.
- Keep non-hook mechanisms like rounds fully compatible.
- Hook dispatch must be fail-open.
- Avoid noisy failure events for mechanisms that simply do not implement the optional hook surface.

# Acceptance Criteria

- `releaseMechanismFunds` best-effort notifies hooked mechanisms after nonzero releases.
- `finalizeRemovedMechanism` best-effort notifies hooked mechanisms before cleanup sweep.
- `AllocationMechanismTCR` best-effort sweeps payout-recipient SuperToken balance back to `budgetTreasury` when the payout recipient is a sweepable flow controlled by the TCR.
- Missing hooks are silent; implemented hooks that revert are observable.
- Targeted tests cover release-hook success/failure, removal-hook success/failure, and terminal payout sweep behavior.

# Open Questions

- None. TeamFlow runtime ownership and exact hook implementation are handled by the separate active runtime task.

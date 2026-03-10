# Goal

Refactor `TeamFlow` from a manager-plus-child-`CustomFlow` stack into a concrete `Flow` runtime that is itself the activated mechanism payout recipient.

# Scope

- `src/teamflow/TeamFlow.sol`
- `src/teamflow/TeamFlowFactory.sol`
- `test/teamflow/TeamFlowFactory.t.sol`
- Matching architecture/product/reference docs that describe TeamFlow deployment/runtime shape

# Constraints

- Preserve the existing `AllocationMechanismTCR` mechanism-factory interface and escrow-funded release flow.
- Keep `TeamFlow` available through `TeamFlowFactory`; do not change allowlist/bootstrap behavior for other mechanism families.
- Keep hard removal semantics for departed seats.
- Avoid unrelated routing / spend-policy work already active in the tree.
- Stay within existing `Flow`/`IFlow` role boundaries unless a change is required for TeamFlow correctness.

# Planned Shape

- `TeamFlow` becomes a concrete `Flow` subclass with its own initializer.
- `TeamFlowFactory` deploys one `TeamFlow` clone and returns the same address for both `mechanism` and `payoutRecipient`.
- TeamFlow seat management updates recipient lifecycle and pool units directly on the deployed flow runtime instead of syncing through a child `CustomFlow`.
- TeamFlow target-rate sync becomes rate-only.
- TeamFlow no longer depends on generic allocation-commit/ppm composition management for seat operations.

# Acceptance Criteria

- Activated TeamFlow mechanisms are valid when `mechanism == payoutRecipient`.
- TeamFlow add/remove seat paths manage recipients and units on the TeamFlow runtime directly.
- TeamFlow rate config and public sync recompute/apply only the target outflow rate.
- Tests cover deployment, role wiring, equal seat units, rate caps, removals, and re-add semantics.
- Docs no longer describe TeamFlow as owning a standalone child `CustomFlow`.

# Open Questions

- Whether TeamFlow should still register itself as the single configured strategy only for `Flow` init compatibility, or whether a narrower Flow-base simplification is worth doing in the same change. Default plan: keep self as the configured strategy unless a cleaner zero-strategy path is clearly low risk.
Status: completed
Updated: 2026-03-10
Completed: 2026-03-10

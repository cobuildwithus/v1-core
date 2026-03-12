# UMA Zero Escalation Manager Simplification

## Goal
Remove UMA escalation-manager configurability from v1 treasury success resolution so success proofs always use the standard OOv3 path with no custom escalation policy surface.

## Scope
- Refactor `UMATreasurySuccessResolver` to stop accepting deploy-time escalation-manager and domain configuration and always assert with zero values.
- Tighten treasury-side assertion validation so accepted assertions require zero escalation-manager address and zeroed escalation-manager policy bits.
- Remove the now-unused resolver config getters from the shared resolver-config interface and test helpers.
- Update focused tests, fake-resolver deployment wiring, and UMA deployment guidance to match the fixed zero-EM v1 model.

## Invariants to Preserve
- One active assertion max per treasury.
- Success remains resolver-gated and OOv3 assertion-backed.
- Treasury acceptance still pins callback recipient, asserting caller, currency, identifier, timing, and bond floor.
- Goal and budget post-deadline resolution semantics remain unchanged aside from rejecting non-zero escalation-manager policy.

## Validation
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s build:sizes`

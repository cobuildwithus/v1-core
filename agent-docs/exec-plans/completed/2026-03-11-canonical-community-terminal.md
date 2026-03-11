# Canonical Community Terminal

## Goal

Make `CobuildPaymentTerminal` the canonical shared community terminal for root and child community topologies, then tighten registration/factory invariants so the terminal, split hook, and registry stay aligned.

## Success Criteria

- Root communities can register the shared terminal as their native/payment terminal without self-rejection.
- Child communities can use that same shared terminal as their upstream payment source without recursive external `pay(...)` calls.
- Community registration cannot drift to a different split hook after first bind.
- Factory/deployment flow reflects the canonical terminal model instead of a sidecar-only wrapper model.
- Regression tests cover the canonical root + child topology and registration guardrails.

## Scope

- Refactor `CobuildPaymentTerminal` self-routing and registration validation.
- Extend `CobuildPaymentTerminalFactory` to reduce post-deploy drift surface.
- Tighten split-hook/runtime validation semantics where current checks are tautological or misleading.
- Gate `deployGoalForCommunity(...)` to the registry owner as part of the hard cutover.
- Update impacted Solidity tests and mocks.
- Update active architecture/spec docs so they describe the canonical-terminal model instead of a sidecar wrapper model.

## Out of Scope

- Broad non-terminal cleanup outside the community routing path.

## Constraints

- Preserve canonical directory-driven discovery for both community and goal terminals.
- Keep fail-closed behavior for same-tx pending-route consumption and reserved-token delivery.
- Do not touch `lib/**`.
- Do not disturb unrelated deploy artifact changes already in the worktree.

## Risks

- Self-terminal native conversion introduces internal path branching in a funds-sensitive contract.
- Factory-flow changes can affect tests and docs assumptions across the community routing stack.
- Split-hook registration hardening may break existing mutable-test setups that assumed overwrite behavior.

## Verification

- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

## Outcome

- Completed 2026-03-11.
- `CobuildPaymentTerminal` is now the canonical shared community terminal, records community pays through the JB terminal store, and supports self-source root/child routing.
- Community registration is immutable, factory deploy+register flow is same-transaction, and contract-wallet owners can authorize registration through EIP-1271 signatures.

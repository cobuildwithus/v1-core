# TCR Request Actor Event Cutover

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Make TCR request actor identities deterministic for downstream indexing by emitting explicit requester, challenger, and dispute request-cycle fields directly from the protocol event surface.

## Scope

- `src/tcr/interfaces/IGeneralizedTCR.sol`
- `src/tcr/interfaces/IEvidence.sol`
- `src/tcr/GeneralizedTCR.sol`
- Targeted TCR tests and matching protocol docs

## Constraints

- Preserve current TCR request/challenge/dispute lifecycle behavior.
- Treat this as a hard cutover with no backward-compatibility shim because there are no live deployments.
- Keep event payloads sufficient for downstream indexing without onchain reads.
- Run required Solidity verification and completion workflow passes before handoff.

## Acceptance Criteria

- `RequestSubmitted` emits the canonical requester address.
- `Dispute` emits both the canonical request index and challenger address.
- Protocol tests cover the new event payloads.
- Downstream consumers can identify removal requester and challenger directly from logs.

## Progress Log

- 2026-03-10: Scoped the cutover to TCR event interfaces, emits, tests, and downstream ABI/indexer consumers.
- 2026-03-10: Added explicit requester payloads to `RequestSubmitted` and explicit request-index/challenger payloads to `Dispute`.
- 2026-03-10: Added focused regression coverage for registration/removal request submitters and dispute challenger/request-cycle emission.
- 2026-03-10: `forge build`, targeted TCR forge tests, `pnpm -s verify:required`, `pnpm -s lint:solidity:warnings`, docs drift, and doc gardening passed before unrelated spend-policy worktree drift deleted `src/goals/policies/UnitsCapSpendPolicy.sol`.
- 2026-03-10: After an audit-driven test-only tweak to use a distinct remover account, a second full Forge gate was blocked by that unrelated spend-policy drift; scoped event/test changes remain isolated to the TCR surface.

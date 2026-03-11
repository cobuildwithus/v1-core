# 2026-03-11 Remove Signed Community Registration

## Goal

- Remove the unused signed community-registration path from `CobuildCommunityTerminal` so community registration is limited to direct owner calls or the approved factory path.

## Out of Scope

- Reworking community payment metadata.
- Reworking factory authorization or reserved-split validation.
- Changing the direct owner registration path.

## Constraints

- Do not touch unrelated dirty worktree edits.
- Keep the approved-factory path intact.
- Remove dead authorization surface rather than preserving compatibility scaffolding.

## Planned Files

- `src/juicebox/CobuildCommunityTerminal.sol`
- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`

## Design Notes

1. Delete `registerCommunityWithSignature(...)`, `registrationDigestOf(...)`, and the private digest helper/constants/errors/imports they require.
2. Keep registration modes explicit:
- direct owner call via `registerCommunity(...)`
- approved factory call via `registerCommunityFromFactory(...)`
3. Update durable docs so they no longer imply EIP-1271 / offchain-signature registration remains part of the intended surface.

## Verification Plan

- Focused Forge tests for community terminal and factory.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes when needed by repo policy.

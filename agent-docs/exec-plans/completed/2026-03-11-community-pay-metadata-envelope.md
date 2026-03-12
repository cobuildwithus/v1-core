# Community Pay Metadata Envelope

## Status

Completed on 2026-03-11.

## Goal

Preserve non-routing payer metadata when community pays go through the canonical `CobuildCommunityTerminal`, while keeping explicit goal routing behavior unchanged.

## Success Criteria

- `CobuildCommunityTerminal.pay(...)` decodes community pay metadata from a single envelope that carries both routing fields and downstream JB payer metadata.
- The embedded JB metadata is forwarded unchanged into `STORE.recordPaymentFrom(...)`.
- Community pay-hook fulfillment exposes the same embedded JB metadata via `JBAfterPayRecordedContext.payerMetadata`.
- Empty metadata remains valid and means no explicit route plus empty downstream JB metadata.
- Regression tests cover terminal-store forwarding and pay-hook context forwarding.
- Canonical architecture/spec docs describe the new envelope shape instead of the old tuple-only encoding.

## Scope

- `src/juicebox/CobuildCommunityTerminal.sol`
- `test/juicebox/CobuildCommunityTerminal.t.sol`
- `test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
- `test/juicebox/helpers/MockTerminalStore.sol`
- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/goal-funding-and-reward-map.md`

## Constraints

- Treat this as a hard cutover. Do not preserve the legacy `abi.encode(uint256[] goalIds, uint32[] weights)` metadata shape.
- Preserve existing reserved-token route seeding and backlog snapshot semantics.
- Do not touch `lib/**`.
- Do not overwrite unrelated in-flight edits in the worktree.

## Design Notes

- Introduce a terminal-local metadata envelope:
  - `goalIds`
  - `weights`
  - `jbMetadata`
- Keep routing extraction and JB metadata extraction adjacent so future pay-path changes cannot drop the non-routing bytes silently.
- Reuse the same embedded JB metadata for both terminal-store accounting and pay-hook context to keep canonical-terminal semantics aligned with standard JB terminals.

## Verification

- Focused Forge tests for `CobuildCommunityTerminal` and community-terminal integration coverage.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

### Results

- `forge build src/juicebox/CobuildCommunityTerminal.sol test/juicebox/helpers/MockTerminalStore.sol test/juicebox/CobuildCommunityTerminal.t.sol test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol` PASS
- `forge test --match-path 'test/juicebox/CobuildCommunityTerminal*.t.sol'` PASS
- `pnpm -s verify:required` PASS
- `pnpm -s lint:solidity:warnings` PASS
- `simplify` pass: kept the behavior change intact, narrowed `_beginRoute(...)` to routing-only args, and hoisted `jbMetadata` into a local before forwarding.
- `test-coverage-audit` pass: added `Pay` event metadata regression coverage on top of store/pay-hook forwarding assertions.
- `task-finish-review` pass: no findings in scope; residual note only for optionally asserting non-empty `jbMetadata` on the indirect native-conversion branch in a future follow-up.

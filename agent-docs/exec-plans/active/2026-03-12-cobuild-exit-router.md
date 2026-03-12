# 2026-03-12 Cobuild Exit Router

Status: completed
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Add the dedicated user exit path described in the handoff: goal-token cash-out should route through a canonical onchain lineage walk rather than arbitrary route inputs.

## Scope

- In scope:
  - `src/juicebox/CobuildCommunityTerminal.sol`
  - `src/juicebox/CobuildExitRouter.sol`
  - `src/interfaces/ICobuildCommunityTerminal.sol`
  - targeted tests for community-terminal cash-out behavior and router lineage traversal
  - matching protocol/runtime docs that describe goal/community funding and exit boundaries
- Out of scope:
  - changing goal ingress/funding behavior in `CobuildGoalTerminal`
  - changing `StakeVault`, `GoalTreasury`, or factory deployment semantics beyond what the router reads
  - adding permit flows or fee-parity machinery beyond the minimal community-terminal cash-out primitive

## Constraints

- Keep the public user API narrow: `exitToCommunityToken`, `exitToCobuildToken`, and `exitToEth`.
- Infer the route onchain from goal treasury + stake-vault context and registered community-terminal configs.
- Respect repo interface policy by using an explicit `src/interfaces/**` boundary instead of an ad hoc inline reader interface.
- Preserve existing community pay routing semantics and fail-closed behavior.
- Avoid stepping on unrelated dirty worktree edits, especially the already-modified architecture docs.

## Intended change

1. Upgrade `CobuildCommunityTerminal` from `IJBTerminal` to `IJBCashOutTerminal` and add a minimal `cashOutTokensOf(...)` implementation that records the cash-out, burns tokens, transfers reclaim, and fulfills cash-out hooks.
2. Add `CobuildExitRouter` that accepts goal tokens, cashes out to the immediate goal payment layer, and then walks the configured community lineage upward until it reaches the requested target layer.
3. Add or extend focused mocks/tests for reclaim accounting, hook fulfillment, unauthorized holder checks, and the inferred community/COBUILD/native exit routes.
4. Update the architecture/spec docs that describe terminal responsibilities and canonical funding/exit surfaces.

## Verification

- targeted forge tests for the community terminal and exit router
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- `pnpm -s build:sizes`
- completion workflow: `simplify` -> `test-coverage-audit` -> `task-finish-review`
- final router hardening adds fail-closed checks for unregistered immediate community layers, enforces `CobuildCommunityTerminal` as the canonical community-hop cash-out terminal, rejects self-beneficiary exits, and covers the `MAX_COMMUNITY_HOPS` ETH boundary in tests.

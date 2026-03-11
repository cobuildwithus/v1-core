# 2026-03-11 Community Live Reserved Split Proof

## Goal

Fail closed unless the community revnet's live reserved-token split group already routes the full reserved bucket to the exact `CobuildSplitHook` being registered.

## Success Criteria

- `CobuildCommunityTerminal.registerCommunity(...)` and `registerCommunityWithSignature(...)` reject registrations when the live reserved split group does not resolve to one full-weight split whose `hook` matches the provided split hook.
- `CobuildCommunityTerminalFactory.deployFor(...)` only succeeds when that invariant is already true for the predicted hook address.
- Regression tests cover both the matching and mismatched live split-hook cases.
- Routing docs explicitly state that registration/deployment is gated on the live reserved split hook match.

## Scope

- `src/juicebox/CobuildCommunityTerminal.sol`
- `test/juicebox/CobuildCommunityTerminal.t.sol`
- `test/juicebox/CobuildCommunityTerminalFactory.t.sol`
- `test/juicebox/CobuildCommunityTerminalCoreIntegration.t.sol`
- `ARCHITECTURE.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/RELIABILITY.md`

## Constraints

- Keep the check aligned with REV's real reserved-token delivery path: current ruleset reserved split group, with the JBSplits fallback behavior preserved by the upstream store.
- Require the full reserved bucket to hit the hook, not just "one of several splits," because `CobuildSplitHook` pending-route accounting assumes one coherent callback bucket.
- Do not touch `lib/**`.

## Intended Shape

- Add a registration-time helper that:
  - resolves the community controller,
  - reads the current ruleset id,
  - fetches the reserved-token split group from `controller.SPLITS().splitsOf(projectId, rulesetId, RESERVED_TOKENS)`,
  - requires exactly one split,
  - requires that split to use `JBConstants.SPLITS_TOTAL_PERCENT`,
  - requires that split's `hook` to equal the registered split hook.
- Update mocks/integration harnesses so tests can model live reserved split state independently from the hook's self-reported config.
- Update routing docs to make the "predicted hook must already be the live reserved split hook" deployment prerequisite explicit, including the requirement to batch the split update and `deployFor(...)` atomically.

## Verification Target

- Focused Forge suites for community terminal, factory, and core integration flows.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`
Status: completed
Updated: 2026-03-11
Completed: 2026-03-11

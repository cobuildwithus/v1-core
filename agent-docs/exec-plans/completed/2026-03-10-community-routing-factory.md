# Community Routing Factory

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Add a canonical factory that deploys the `CobuildSplitHook` + `CobuildPaymentTerminal` pair atomically, keeps `routeSetter` fixed at initialization, and removes the current deployment-order footgun without introducing a post-deploy setter.

## Scope

- In scope:
  - Harden `CobuildSplitHook.initialize(...)` so `routeSetter` must be a deployed contract.
  - Add a deterministic deploy factory for the community routing pair.
  - Adjust `CobuildPaymentTerminal` so it can be deployed before hook initialization and still fail closed on misconfiguration.
  - Add regression tests for factory deployment, address prediction, and misconfiguration rejection.
  - Update architecture/product docs for the canonical deployment path.
- Out of scope:
  - Changing routing semantics beyond the deployment/configuration surface.
  - Adding a mutable or one-time `routeSetter` setter.
  - Touching `lib/**`.

## Constraints

- Keep `routeSetter`, goal registry, and goal deployment registry init-fixed.
- Keep wrapper-routed pays fail-closed if the hook pair is misconfigured.
- Preserve current dirty worktree routing changes and integrate with them instead of reverting.
- Verification required:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`

## Acceptance criteria

- Canonical deployment can create both routing contracts in one transaction through the new factory.
- The hook rejects non-contract `routeSetter` addresses during initialization.
- The wrapper no longer depends on pre-initialized hook state in its constructor, but still rejects misconfigured pair usage before routing funds.
- Tests cover deterministic address prediction and the deployment-order regression.
- Routing docs describe the factory as the canonical deployment path.

## Progress log

- 2026-03-10: Defined factory-first approach to avoid a one-time setter while preserving fixed init-time authority.
- 2026-03-10: Added `CobuildPaymentTerminalFactory`, hardened `routeSetter` contract validation, moved wrapper hook checks to pay-time fail-closed validation, and updated deployment/docs/tests.
- 2026-03-10: Verified with focused Forge suites, `pnpm -s verify:required`, and `pnpm -s lint:solidity:warnings`.

## Open risks

- The worktree already contains uncommitted routing refactors in the same files; edits must merge cleanly with those changes.

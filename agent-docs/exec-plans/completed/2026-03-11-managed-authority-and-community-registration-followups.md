# 2026-03-11 Managed Authority And Community Registration Follow-Ups

## Goal

- Close the managed-preset authority/strategy control gap by making newly deployed managed child-budget strategies controller-owned/controller-allocated and exposing an authority-gated controller entrypoint for child-budget allocation writes.
- Remove redundant factory registration signatures by giving the shared community terminal an explicit trusted-factory registration path.
- Pin direct-native community configs so `paymentSourceRevnetId` matches the community revnet when `directNativeAllowed == true`.

## Out of Scope

- Reworking the ETH -> child-community upstream side-effect model.
- Restoring backward-compatible dual metadata decoding for legacy 2-field community pay metadata.
- Rewriting existing child-flow `recipientAdmin` ownership away from the Safe in managed v1.

## Constraints

- Do not overwrite unrelated dirty worktree edits.
- Keep managed allocator identity controller-centric; authority rotation should not require strategy ownership migration.
- Treat the community-factory fast path as a hard cutover for this branch rather than preserving the redundant signature requirement.

## Planned Files

- `src/goals/ManagedBudgetController.sol`
- `src/interfaces/IManagedBudgetController.sol`
- `src/goals/ManagedBudgetControllerStackDeployer.sol`
- `src/juicebox/CobuildCommunityTerminal.sol`
- `src/juicebox/CobuildCommunityTerminalFactory.sol`
- `test/goals/ManagedBudgetController.t.sol`
- `test/goals/ManagedBudgetControllerStackDeployer.t.sol`
- `test/goals/GoalFactorySpendPolicyDeploy.t.sol`
- `test/juicebox/CobuildCommunityTerminal.t.sol`
- `test/juicebox/CobuildCommunityTerminalFactory.t.sol`
- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/references/module-boundary-map.md`
- `agent-docs/references/goal-funding-and-reward-map.md`

## Design Notes

1. Managed child-budget strategies:
- Keep `authority` as the child-flow `recipientAdmin` input for v1 lifecycle/admin behavior.
- Change strategy owner + allocator wiring from `authority` to `controller`.
- Add a controller method for authority-gated child-budget allocation commits so controller-owned strategies remain usable.

2. Community registration fast path:
- Add an optional immutable `approvedFactory` on `CobuildCommunityTerminal`.
- Let that approved factory call a dedicated registration entrypoint without a separate owner signature.
- Remove signature/deadline fields from the factory deploy config and use the trusted-factory path there.

3. Direct-native config invariant:
- Reject registration when `directNativeAllowed == true` and `paymentSourceRevnetId != communityRevnetId`.

## Verification Plan

- Focused Forge tests for managed controller, managed stack deployer, goal factory managed preset wiring, community terminal, and community terminal factory.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

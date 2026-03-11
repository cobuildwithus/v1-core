# 2026-03-11 Managed Authority Rotation Fix

Status: completed
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Remove the managed-preset split-brain control path by making the `ManagedBudgetController` contract the child-flow `recipientAdmin` identity as well as the child-budget allocator identity.
- Preserve the existing Safe authority handoff surface (`transferAuthority` / `acceptAuthority`) without requiring rewrites of already-created managed child flows in the same controller instance.

## Scope

- In scope:
  - `src/goals/ManagedBudgetController.sol`
  - `src/goals/ManagedBudgetControllerStackDeployer.sol`
  - `src/interfaces/IManagedBudgetControllerStackDeployer.sol`
  - managed-preset tests that assert child-flow role wiring or authority rotation behavior
  - architecture/product docs that still describe Safe-direct managed child `recipientAdmin`
- Out of scope:
  - open-preset `BudgetTCR` stack behavior
  - migration scaffolding for already-deployed historical managed stacks outside this branch
  - adding a new per-budget controller layer

## Constraints

- Keep controller-owned allocator identity intact for both goal and child strategies.
- Prefer hard cutover over compatibility scaffolding; repo hard rules still state there are no live deployments yet.
- Do not overwrite unrelated dirty worktree changes from other active streams.

## Intended Shape

1. `ManagedBudgetController.createBudget(...)` creates child flows with `recipientAdmin = address(this)`.
2. Managed stack preparation no longer takes or validates the external Safe authority address, because child authority is controller-centric.
3. Authority rotation remains controller-local, but that is now sufficient because existing child flows and child strategies stay bound to the controller contract.
4. Managed preset docs stop describing Safe-direct child `recipientAdmin` ownership and instead describe controller-owned child admin/allocator identity.

## Test Plan

- Managed controller budget creation asserts child `recipientAdmin == address(controller)`.
- Managed real-stack and goal-factory managed-preset tests assert the same controller-owned child admin identity.
- Authority-rotation regression keeps post-rotation child-flow allocation writes working through the controller without any Safe ownership on child flows.

## Risks

- Interface/signature cutover for `prepareBudgetStack(...)` can break tests or pending managed-preset wiring if any remaining call sites still pass the old authority arg.
- Doc drift is likely because several architecture/spec references still encode the old v1 Safe-direct note.

## Outcome

- Managed child flows now keep `ManagedBudgetController` as `recipientAdmin`, so Safe authority rotation stays controller-centric for both child admin and child allocation control.
- The controller now exposes authority-gated child recipient lifecycle wrappers, and managed-preset regression coverage exercises post-rotation child admin + allocation writes.
- Required Solidity verification completed successfully with `pnpm -s verify:required` and `pnpm -s lint:solidity:warnings`.

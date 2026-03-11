# V4 Hook Deploy Script (2026-03-04)

## Goal

Add a dedicated Foundry deploy script that deploys `CobuildRoutedV4Hook` with valid Uniswap v4 hook address flags, and expose a package command for operators.

## Scope

- Add `script/DeployCobuildRoutedV4Hook.s.sol`.

## Constraints

- Keep existing GoalFactory deploy scripts unchanged in behavior.
- Deploy hook via mined CREATE2 address satisfying `BaseHook` permission-bit validation.
- Emit deployment artifact under `deploys/` using shared `DeployScript` helper pattern.

## Verification

- Run `pnpm -s verify:required`.
- Run `pnpm -s lint:solidity:warnings`.

## Status

- Implemented `script/DeployCobuildRoutedV4Hook.s.sol`.
- Verification passed on 2026-03-04:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`

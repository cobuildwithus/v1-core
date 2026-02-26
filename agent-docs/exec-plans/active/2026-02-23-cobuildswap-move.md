# Move CobuildSwap Into Protocol Repo

Status: completed
Created: 2026-02-23
Updated: 2026-02-23

## Goal

Move the deployed Cobuild swap contract surface from `../flow-contracts` into this `protocol` repo so it builds and can be maintained here.

## Scope

- In scope:
  - Port `CobuildSwap` and `ICobuildSwap` into `src/`.
  - Align imports with this repo's canonical external interface policy.
  - Add required Uniswap dependency/remapping wiring without touching `lib/**`.
- Out of scope:
  - Deployment script migration.
  - Fork/integration test migration from `flow-contracts`.

## Constraints

- Never modify `lib/**`.
- Use canonical external interfaces (local package imports or exact upstream copies).
- Run required Solidity verification gate before handoff.

## Acceptance criteria

- `CobuildSwap` and `ICobuildSwap` exist in `protocol/src` and compile in this repo.
- Uniswap v4 and Universal Router imports resolve via `node_modules` remappings.
- Permit2 interface use is moved out of inline declarations into `src/interfaces/**`.

## Progress log

- 2026-02-23: Located source contract/interface in `../flow-contracts/src/experimental/**`.
- 2026-02-23: Added Uniswap package deps (`@uniswap/v4-core`, `@uniswap/v4-periphery`, `@uniswap/universal-router`).
- 2026-02-23: Ported `CobuildSwap` and `ICobuildSwap`; rewired Juicebox imports to `@bananapus/core-v5`, OZ v5 import path, and extracted Permit2 interface usage to `src/interfaces/external/uniswap/permit2/**`.
- 2026-02-23: Simplified dependency surface by replacing package-level Universal Router import with local canonical `IUniversalRouter` interface copy and removing `@uniswap/universal-router` dependency/remapping.
- 2026-02-23: Added swap-focused test suite at `test/swaps/CobuildSwap.t.sol` and extended coverage to 0x, Zora, and Juicebox success/revert paths plus fee-floor behavior.
- 2026-02-23: Coverage audit and completion audit run via fresh subagents; no remaining high-severity findings.
- 2026-02-23: Verification complete: `forge build -q`, `forge test --match-path test/swaps/CobuildSwap.t.sol`, and final `pnpm -s verify:required` queue run `20260223T213259Z-pid1856-15048` (exit 0).

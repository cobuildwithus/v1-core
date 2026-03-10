# Wrapper Sync Reserved Routing

## Goal

Make wrapper-driven routed mints fund goal treasuries in the same transaction while preserving the user's chosen route.

## Why

`nana-core-v5` only invokes the reserved-token split hook when `sendReservedTokensToSplitsOf(projectId)` is called. The wrapper was assuming the hook ran during `pay()`, so explicit routes reverted and historical routes could be cleared or misapplied.

## Approach

1. Wrapper reads the community controller from the directory.
2. Wrapper rejects routed mints if the community already has pending reserved tokens.
3. Wrapper seeds the pending route, executes the community `pay()`, then synchronously calls `sendReservedTokensToSplitsOf(projectId)` if new reserved tokens were created.
4. Wrapper cancels the pending route only when no reserved tokens were created.
5. Unit, integration, and architecture docs were updated around the same-transaction routing contract.

## Verification

- `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol -vv`
- `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol -vv`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

## Notes

- This preserves the desired UX for wrapper-driven mints only.
- Raw direct community pays remain asynchronous and do not carry per-payment route intent.

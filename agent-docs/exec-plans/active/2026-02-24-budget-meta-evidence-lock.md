# BudgetTCR Meta-Evidence Lock + Content Addressing

## Objective
- Prevent post-deploy social-rule drift in BudgetTCR by freezing meta-evidence after initialization.
- Require BudgetTCR meta-evidence references to be content-addressed (IPFS/Arweave URI or raw CID/txid).

## Scope
- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/BudgetTCR.sol`
- `src/tcr/interfaces/IBudgetTCR.sol`
- `test/BudgetTCR.t.sol`
- `test/BudgetTCRFactory.t.sol`
- `agent-docs/references/tcr-and-arbitration-map.md`
- `src/tcr/README.md`

## Plan
1. Make base `setMetaEvidenceURIs` overrideable (`virtual`).
2. Add BudgetTCR-specific init-time validation of meta-evidence reference format.
3. Override BudgetTCR runtime `setMetaEvidenceURIs` to revert (`META_EVIDENCE_LOCKED`).
4. Add tests for rejection/acceptance and lock behavior.
5. Update docs for the new invariant.
6. Run required verification workflow and handoff.

## Verification
- `pnpm -s verify:required`
- targeted TCR tests when shared-lane artifacts are stale/noisy

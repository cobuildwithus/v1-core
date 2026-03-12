# UMA Deployment Recommendations

Last reviewed: 2026-03-12

## Purpose

This guide defines recommended UMA deployment defaults for this protocol and separates:

- protocol/UMA-required constraints, and
- operator policy defaults (for example `USDC` and `$750` bond).

## Recommended Baseline Defaults (Pre-Launch)

Use these as the default deployment profile unless a goal/budget has unusually high value-at-risk.

| Setting | Recommended baseline | Why |
| --- | --- | --- |
| `assertionCurrency` | `USDC` | Deep liquidity and familiar ops profile. Matches common market-resolution practice. |
| `successAssertionBond` | `750 USDC` (`750e6` in 6-decimal units) | Reasonable anti-spam/economic-signaling baseline aligned with Polymarket's commonly cited operator policy. |
| `successAssertionLiveness` | `2 hours` (`7200`) | Fast resolution baseline; increase for higher-value treasuries. |
| `oracleConfig.oracleSpecHash` + `oracleConfig.assertionPolicyHash` (Budget TCR listings) | Non-zero hashes | Required by current validator bounds. |

## Required Minimums vs Defaults

### UMA/Protocol-Required

- UMA OOv3 enforces a dynamic minimum bond per currency via `getMinimumBond(currency)`.
- This protocol already enforces an effective floor at assertion time:
  - `effectiveBond = max(successAssertionBond, optimisticOracle.getMinimumBond(assertionCurrency))`.
- V1 treasury acceptance is fixed to the standard OOv3 path:
  - `escalationManager == address(0)`,
  - `domainId == bytes32(0)`,
  - `arbitrateViaEscalationManager == false`,
  - `discardOracle == false`,
  - `validateDisputers == false`.
- Treasuries also verify resolver, currency, liveness window, and bond threshold before accepting success.
- Canonical success-spec / assertion-policy text must be registered onchain in `SuccessAssertionDocumentRegistry` before `assertSuccess(...)` can succeed.
- Non-empty assertion evidence is stored onchain at assertion time in that same registry under `keccak256(bytes(evidence))`.

### Operator Policy (Configurable)

- `USDC` is a recommended default, not a UMA-mandated currency.
- `$750` is a recommended baseline, not a UMA global minimum.
- If `successAssertionBond` is configured below UMA's current minimum, actual posted bond will still be raised to UMA minimum by resolver logic.

## Comparison: Polymarket vs This Protocol

Polymarket uses a bond policy commonly communicated as `$750`, but that value is operational policy rather than a hard UMA-wide constant.

- In Polymarket's public adapter flow, bond and liveness are request parameters; when bond is `0`, default oracle bond behavior is used.
- In this protocol, bond/liveness are treasury config values validated by resolver + treasury checks, with OOv3 minimum-bond clamping.

Net: adopting `USDC + 750` as this protocol's default is reasonable, but treat it as governance/ops policy that can be updated.

## Deployment Checklist

1. Deploy `UMATreasurySuccessResolver` with:
   - chain's canonical UMA OOv3,
   - `USDC` as `assertionCurrency`,
   - protocol `SuccessAssertionDocumentRegistry`.
   - no escalation manager or custom domain; v1 hardcodes zero values.
2. Register the canonical spec/policy text onchain and verify `keccak256(bytes(text))` matches each configured treasury/listing hash.
3. No separate UMA parameter sync call is required: resolver `assertSuccess(...)` syncs UMA parameters before assertion.
4. Set treasury defaults:
   - `successAssertionBond = 750e6`,
   - `successAssertionLiveness = 7200`.
5. For Budget TCR deployment, set global `oracleValidationBounds` to match policy defaults so listings cannot drift.
6. Verify on-chain before launch:
   - `getMinimumBond(USDC)` value,
   - resolver currency/address wiring,
   - registry contains the configured spec/policy text for each hash,
   - successful dry-run assertion and settlement path.

## Suggested Override Bands (Policy)

These are operator recommendations, not protocol rules.

| Estimated value-at-risk secured by assertion | Suggested bond | Suggested liveness |
| --- | --- | --- |
| up to `$250k` | `$750` | `2h` |
| `$250k` to `$1m` | `$2,500` | `6h` |
| above `$1m` | `$5,000+` | `24h` |

## Source Notes

- Polymarket resolution docs (`$750` operator bond guidance).
- Polymarket UMA adapter behavior (custom bond/liveness parameters, default handling on `0`).
- UMA OOv3 data-asserter docs (`setBond`, `getMinimumBond`).
- Internal implementation:
  - `src/goals/SuccessAssertionDocumentRegistry.sol`
  - `src/goals/UMATreasurySuccessResolver.sol`
  - `src/goals/GoalTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/tcr/library/BudgetTCRValidationLib.sol`

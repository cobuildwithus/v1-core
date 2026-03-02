# Manager Reward Pool Migration Proposal (PremiumEscrow Hardening)

## Summary

We want to harden underwriter slashing inputs in `PremiumEscrow` so they cannot be inflated by arbitrary token transfers or unrelated inbound streams.

Today, slashing uses `premiumEarned`, which is derived from escrow balance deltas. That means third parties can grief by sending SuperTokens to escrow and increasing slash basis without being part of the manager reward stream.

## Problem To Solve

Current behavior mixes two different sources of value:

1. Protocol-intended manager reward inflow (budget child flow manager stream).
2. Arbitrary external inflow to escrow (direct transfers, unrelated streams).

Because both affect escrow balance, both currently affect `premiumEarned`, and therefore can affect slashing weight.

## Proposed Fix (Pool-Based Manager Reward Distribution)

Move manager reward accounting to an explicit Superfluid pool path so slash basis comes from protocol-native pool accounting, not escrow token balance deltas.

### Core design

1. Create a dedicated manager reward distribution pool for each budget child flow.
2. Route the child flow manager reward outflow into that pool.
3. Make `PremiumEscrow` a pool member and connect it to the manager reward pool.
4. Compute slash basis from pool cumulative received values for escrow membership (pool-native accounting), not from raw escrow balance deltas.

## Required PremiumEscrow API Addition

Add a function on `PremiumEscrow` to connect escrow to the manager reward pool:

- `connectManagerRewardPool(address managerRewardPool)`

Recommended constraints:

1. One-time or tightly controlled reconfiguration.
2. Callable only by authorized budget control surface (for example budget treasury/controller).
3. Validate nonzero and deployed pool address.
4. Record an initial pool cumulative baseline so future deltas are well-defined.

## Accounting Model After Migration

1. **Slashing basis**:
   - Derived from manager reward pool cumulative received deltas for escrow.
   - Excludes arbitrary direct token transfers to escrow.

2. **Premium payout path**:
   - Keep existing payout semantics initially (claim/checkpoint behavior) unless intentionally changed.
   - If payout semantics remain unchanged, maintain explicit handling for orphan/terminal edge cases.

## Why this helps

1. Uses protocol-native accounting for streamed/distributed rewards.
2. Removes griefing vector where direct transfers can inflate slashing inputs.
3. Improves auditability: slash basis is tied to a single intended reward channel.

## Important Implementation Notes

1. Clarify naming to reduce confusion:
   - Current `managerRewardPool` behaves as a generic sink address.
   - Consider renaming externally documented concept to `managerRewardSink` or `managerRewardDistributionTarget`.

2. Distributor permissions must be explicit:
   - Pool configuration must prevent unintended third-party distribution from polluting slash basis.

3. Deployment/wiring order must be defined:
   - Manager reward pool must exist and be connected correctly before slashing accounting begins.

## Acceptance Criteria

1. Direct SuperToken transfer to escrow does **not** increase slash basis.
2. Manager reward pool distributions to escrow **do** increase slash basis.
3. Existing slashing lifecycle invariants remain intact (activation gating, idempotency, terminal checks).
4. Integration tests cover pool connect/setup, slash basis deltas, and hostile external transfer attempts.

# Reliability

## Core Invariants

1. Lifecycle transitions should be explicit and monotonic.
2. Allocation and flow-rate updates should remain deterministic and bounded.
3. Cross-contract integrations should fail safely and preserve core state invariants.
4. Regression tests should exist for each bugfix or high-risk path.

## Reliability-Critical Surfaces

### Flow allocation and child-sync

- `src/Flow.sol`
- `src/flows/CustomFlow.sol`
- `src/library/FlowAllocations.sol`
- `src/library/FlowRates.sol`
- `src/library/FlowPools.sol`
- `src/library/FlowRecipients.sol`

### Goal/Budget funding, underwriting, and resolution

- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/StakeVault.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/UnderwriterSlasherRouter.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/juicebox/CobuildPaymentTerminal.sol`

### TCR + arbitrator

- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `src/tcr/library/TCRRounds.sol`

## Common Failure Modes and Expected Behavior

1. Flow recipient/allocation mismatch or stale child updates
- Should remain recoverable via explicit child-sync update paths without corrupting allocations.

2. Treasury deadline/threshold edge conditions
- Must avoid ambiguous activation/finalization outcomes at boundary timestamps.

3. Hook/token conversion mismatch
- Funding ingress should reject unsupported or inconsistent token/value combinations.

4. Dispute/request timing races
- TCR challenge and timeout semantics should remain explicit and test-backed.

5. Child-sync and premium-checkpoint downstream failures
- Parent allocation commits remain live when downstream child-sync calls fail; failures stay observable and permissionlessly repairable.
- Premium-checkpoint failures are fail-closed and must revert allocation commits to preserve underwriting accounting integrity.

6. Community wrapper/split-hook route handoff mismatch
- Explicit routed community pays must fail closed when the pending route is not consumed in the same transaction.
- Direct community pays with no explicit/default route should escrow reserved tokens instead of inferring a downstream route.

## Verification Matrix

- Build sanity: `forge build -q`
- Default regression pass: `pnpm -s test:lite`
- Full or focused runs: `forge test -q`, targeted `--match-path`/`--match-test`
- Coverage gate path: `pnpm -s test:coverage:ci`
- Doc consistency: `bash scripts/check-agent-docs-drift.sh`
- Doc freshness: `bash scripts/doc-gardening.sh --fail-on-issues`

## High-Value Tests To Keep Healthy

- `test/flows/*.t.sol`
- `test/goals/*.t.sol`
- `test/GeneralizedTCR*.t.sol`
- `test/ERC20VotesArbitrator*.t.sol`
- `test/invariant/*.t.sol`

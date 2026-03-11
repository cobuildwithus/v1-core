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
- `src/goals/policies/*.sol`
- `src/goals/StakeVault.sol`
- `src/goals/BudgetStakeLedger.sol`
- `src/goals/PremiumEscrow.sol`
- `src/goals/UnderwriterSlasherRouter.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/juicebox/CobuildCommunityTerminal.sol`

### TCR + arbitrator

- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `src/tcr/library/TCRRounds.sol`

## Common Failure Modes and Expected Behavior

1. Flow recipient/allocation mismatch or stale child updates
- Should remain recoverable via explicit child-sync update paths without corrupting allocations.

2. Treasury deadline/threshold edge conditions
- Must avoid ambiguous activation/finalization outcomes at boundary timestamps.

3. Spend-policy target/sync mismatch
- Policy-selected target math and sync mode must preserve legacy behavior when unset and must not desynchronize applied outflow from treasury topology or buffer constraints.

4. Hook/token conversion mismatch
- Funding ingress should reject unsupported or inconsistent token/value combinations.

5. Dispute/request timing races
- TCR challenge and timeout semantics should remain explicit and test-backed.

6. Child-sync and premium-checkpoint downstream failures
- Parent allocation commits remain live when downstream child-sync calls fail; failures stay observable and permissionlessly repairable.
- Premium-checkpoint failures are fail-closed and must revert allocation commits to preserve underwriting accounting integrity.

7. Community terminal/split-hook route handoff mismatch
- Canonical-terminal-routed community pays must snapshot preexisting pending reserved-token backlog so a user-selected route only
  captures the current pay's newly created reserved-token delta.
- `CobuildSplitHook` must only receive the full reserved-token split bucket; fractional split callbacks should revert
  instead of being treated as coherent backlog/new-delta accounting input.
- If a canonical-terminal-routed pay creates reserved tokens, the terminal must force `sendReservedTokensToSplitsOf(...)` in the
  same transaction and fail closed only if the pending route still is not consumed after routing the current pay's new
  delta.
- If a canonical-terminal-routed pay creates no reserved tokens, the terminal should clear the unused pending route instead of
  leaving stale routing state behind.
- Community routing must only honor registry-selectable goals and must route the full explicit pending-route amount.
- Explicit routed community pays should update historical routing volume with the full routed amount; backlog flushes must
  not make the historical signal self-reinforcing.
- Hook-managed historical backlog should be flushed through the paginated permissionless path instead of piggybacking
  older backlog through unrelated direct community pays.
- Historical backlog must be derived from observed explicit routes only; direct community pays without a pending route
  should defer the full callback amount instead of inferring a downstream route.
- Permissionless backlog flushes should use each registry-listed goal's treasury as the downstream beneficiary sink.

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

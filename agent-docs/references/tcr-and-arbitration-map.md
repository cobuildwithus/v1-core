# TCR and Arbitration Map

## Request Lifecycle

1. Add/remove request submitted in `GeneralizedTCR`.
2. Request deposits and arbitration cost snapshots are recorded.
3. Challenge window allows dispute creation.
4. If challenged, arbitrator dispute is created and linked back to item/request.

## Arbitration Lifecycle

1. `ERC20VotesArbitrator.createDispute` initializes voting round windows.
2. Commit/reveal voting determines round result.
   - Voting power source is either ERC20Votes snapshots (default) or stake-vault juror snapshots when configured.
   - In stake-vault mode, `commitVoteFor` supports delegated commit for authorized juror operators.
3. Ruling execution feeds back into TCR `rule(...)` resolution path.
4. Contributors withdraw rewards/refunds via round accounting.
5. In stake-vault mode, `slashVoter` permissionlessly applies 10 bps slashing for missed reveal or incorrect vote (non-tie), transferring slashed stake to goal reward escrow.
   - Slash settlement draws from the juror's live stake balances, so post-snapshot juror exits do not zero out slashability.

## Timeout Path

- Solved-but-unexecuted disputes can be resolved via timeout logic once dispute timeout conditions are met.

## Budget TCR Extension Path

1. Budget listing add/remove lifecycle still runs through `GeneralizedTCR` request/challenge/dispute flow.
2. On accepted registration, `BudgetTCR` only queues pending activation (`BudgetStackActivationQueued`) so TCR request resolution is not coupled to deployment/flow side effects.
3. Any caller can run `activateRegisteredBudget(...)` to execute `BudgetTCRDeployer.prepareBudgetStack(...)` and deploy:
   - `GoalStakeVault`
   - `BudgetStakeStrategy` (pins `recipientId`, then reads per-budget stake via `BudgetStakeLedger.budgetForRecipient(...)`)
   - no per-budget temporary-manager/forwarder contract.
4. `activateRegisteredBudget(...)` (as goal-flow `recipientAdmin`) adds the goal-flow recipient with explicit child roles (`recipientAdmin`, `flowOperator`, `sweeper`) where `recipientAdmin` is the per-budget `AllocationMechanismTCR` and operator/sweeper remain the cloned budget treasury, then calls `BudgetTCRDeployer.deployBudgetTreasury(...)`.
5. On accepted removal, `BudgetTCR` clears any pending registration and queues pending removal finalization (`BudgetStackRemovalQueued`) so TCR request resolution remains uncoupled from flow calls.
6. Any caller can run `finalizeRemovedBudget(...)` to remove parent recipient + stake-ledger mapping, then attempt terminal-only budget resolution (`forceFlowRateToZero`, controller-gated `resolveFailure` via `BudgetTCR`).
7. If terminalization is not yet allowed by treasury deadlines after removal finalization, anyone can retry the terminal-only path via `retryRemovedBudgetResolution(...)`.
8. Factory-time deployment requires a caller-provided `IVotes` token and clones pre-deployed `BudgetTCR`, arbitrator, and deployer implementations.
9. `BudgetTCRFactory` does not use ERC1967 proxy paths for BudgetTCR runtime instances.

## Round Stack Notes

- `RoundFactory` is permissionless and may emit non-canonical `RoundDeployed` events for arbitrary configurations.
- Canonical budget rounds for product/indexing should be sourced from `AllocationMechanismTCR.RoundActivated`, which links an accepted mechanism listing item id to the activated deployed stack.
- `RoundSubmissionTCR` submission windows are bounded by `startAt` (inclusive lower bound) and `endAt` (inclusive upper bound).
- `RoundPrizeVault` has no sweep/closeout path by design; only entitled submissions can claim, and unentitled balances remain in-vault.

## Invariants

- Arbitrator token and arbitrable contract must be compatible.
- Request/challenge economics are snapshotted and should remain deterministic.
- Arbitrator and arbitrator extra data are deployment-configured and immutable after initialization.
- Dispute mappings and round accounting should remain internally consistent.
- Budget stack helper deployment side effects are only callable through `BudgetTCRDeployer.onlyBudgetTCR`.
- Goal flow `recipientAdmin` must be configured to the per-goal `BudgetTCR` for budget recipient add/remove operations.
- Budget child flow `recipientAdmin` must be configured to the per-budget `AllocationMechanismTCR` for round recipient add/remove operations.
- BudgetTCR runtime meta-evidence updates are locked after initialization.
- Deployment-time meta-evidence should be content-addressed (IPFS/Arweave URI or raw CID/txid string).

## Key Files

- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/ERC20VotesArbitrator.sol`
- `src/tcr/BudgetTCR.sol`
- `src/tcr/BudgetTCRDeployer.sol`
- `src/tcr/BudgetTCRFactory.sol`
- `src/tcr/AllocationMechanismTCR.sol`
- `src/tcr/RoundSubmissionTCR.sol`
- `src/rounds/RoundFactory.sol`
- `src/rounds/RoundPrizeVault.sol`
- `src/tcr/library/TCRRounds.sol`
- `src/tcr/utils/ArbitrationCostExtraData.sol`
- `src/tcr/storage/GeneralizedTCRStorageV1.sol`
- `src/tcr/storage/ArbitratorStorageV1.sol`

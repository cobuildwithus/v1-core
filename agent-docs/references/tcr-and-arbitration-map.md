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
5. In stake-vault mode, `slashVoter` permissionlessly applies configured slashing for missed reveal or incorrect vote (non-tie):
   - caller bounty transfers to the slashing caller,
   - remaining slash transfers to winner pools when a winner exists, otherwise to `invalidRoundRewardsSink`,
   - by intentional policy, "missed reveal" includes jurors who never committed in that round (`!receipt.hasRevealed`), so non-participation can be slashable after solved rounds,
   - slash settlement draws from the juror's live stake balances, so post-snapshot exits do not zero slashability.

## Timeout Path

- Solved-but-unexecuted disputes can be resolved via timeout logic once dispute timeout conditions are met.

## Budget TCR Extension Path

1. Budget listing add/remove lifecycle still runs through `GeneralizedTCR` request/challenge/dispute flow.
2. On accepted registration, `BudgetTCR` queues pending activation (`BudgetStackActivationQueued`) so TCR request resolution is not coupled to deployment/flow side effects.
3. Any caller can run `activateRegisteredBudget(...)` to execute `BudgetTCRDeployer.prepareBudgetStack(...)` and prepare:
   - `StakeVault`,
   - shared `BudgetFlowRouterStrategy` wiring against `BudgetStakeLedger`,
   - per-budget `PremiumEscrow` clone.
4. `activateRegisteredBudget(...)` (as goal-flow `recipientAdmin`) adds the goal-flow recipient with explicit child roles:
   - `recipientAdmin`: per-budget `AllocationMechanismTCR`,
   - `flowOperator`: cloned budget treasury,
   - `sweeper`: cloned budget treasury,
   - child manager-reward pool: per-budget premium escrow at configured `budgetPremiumPpm`.
5. On accepted delisting (on-chain remove/finalize-removed path), `BudgetTCR` clears any pending registration and queues pending removal finalization (`BudgetStackRemovalQueued`) so TCR request resolution remains uncoupled from flow calls.
6. Any caller can run `finalizeRemovedBudget(...)` to remove parent recipient + stake-ledger mapping and enforce `forceFlowRateToZero`:
   - pre-activation delistings strict-finalize through controller-gated failure resolution,
   - activation-locked delistings do not auto-force failure.
7. If a delisted budget remains unresolved after finalization, anyone can call `retryRemovedBudgetResolution(...)`:
   - pre-activation delistings retry terminal-only resolution,
   - activation-locked delistings retry spend-stop + treasury `sync()` progression.
8. Factory-time deployment requires a caller-provided `IVotes` token and clones pre-deployed `BudgetTCR`, arbitrator, and deployer implementations.
9. `BudgetTCRFactory` does not use ERC1967 proxy paths for BudgetTCR runtime instances.

## Mechanism Registry Notes

- `RoundFactory` is a permissionless implementation of the generic allocation-mechanism factory interface and may emit non-canonical `RoundDeployed` events for arbitrary configurations.
- Canonical round deployments use stake-vault-backed voting power but intentionally hardcode non-slashing arbitrators; only the budget TCR and allocation-mechanism TCR arbitrators are router-authorized slashers.
- `AllocationMechanismTCR` now gates mechanism deployment factories through one governor-managed control:
  - `mechanismFactoryAllowed[factory]` allowlist.
- Mechanism deployment config (factory + opaque mechanism payload) is immutable per curated listing payload.
- Activation uses the listing's configured mechanism factory, with allowlist enforcement at submission-time validation and activation-time execution.
- Canonical mechanism activations for product/indexing should be sourced from `AllocationMechanismTCR.MechanismActivated`, which links an accepted mechanism listing item id to the activated deployed stack.
- `RoundSubmissionTCR` submission windows are bounded by `startAt` (inclusive lower bound) and `endAt` (inclusive upper bound).
- `RoundPrizeVault` has no sweep/closeout path by design; only entitled submissions can claim, and unentitled balances remain in-vault.

## Invariants

- Shared registry init config is canonicalized in the TCR layer:
  - `GeneralizedTCR` consumes one shared registry config shape.
  - `BudgetTCR` and `AllocationMechanismTCR` wrap that shared config only for contract-specific extras.
  - Round deployment carries the shared registry policy until factory-derived arbitrator/token/deposit-strategy refs are known.
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

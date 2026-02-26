# TCR (Generalized Token Curated Registry)

This folder contains the core contracts for a generalized token curated registry (TCR) with ERC20Votes-based arbitration. The system follows a request/challenge flow: anyone can request to add or remove an item, and others can challenge that request within a challenge period. Disputed requests are resolved by an on-chain arbitrator using token-based voting.

This implementation is adapted from Kleros' GeneralizedTCR with Cobuild-specific changes (ERC20 arbitration costs and configurable submission deposit strategies).

## High-level architecture

- **Registry core:** `GeneralizedTCR.sol` (abstract) manages items, requests, and dispute accounting.
- **Arbitrator:** `ERC20VotesArbitrator.sol` resolves disputes via commit/reveal voting using an ERC20Votes-compatible token.
- **Strategies:** `strategies/` contains optional policies for handling submission deposits.
- **Interfaces, storage, utils:** `interfaces/`, `storage/`, `library/`, and `utils/` provide the public surface area and internal helpers.

## Core concepts

- **Item:** arbitrary `bytes` data representing the thing being curated. Default `itemID` is `keccak256(item)`.
- **Status:** `Absent`, `Registered`, `RegistrationRequested`, `ClearingRequested`.
- **Request:** a request to add or remove an item, with a challenge window and optional dispute.
- **Round:** a dispute funding round tracking requester/challenger contributions and rewards.
- **Parties:** `Requester` (the request submitter), `Challenger`, or `None` (tie/refuse).

## Contract map

- `GeneralizedTCR.sol`
  - Core request/challenge logic and item lifecycle.
  - Abstract hooks: `_verifyItemData`, `_constructNewItemID`, `_onItemRegistered`, `_onItemRemoved`.
  - Non-upgradeable runtime; core parameters are initialization-only.
- `ERC20VotesArbitrator.sol`
  - Commit/reveal voting with ERC20Votes token.
  - Arbitration cost is paid in the same token used for deposits.
  - Non-upgradeable runtime; invalid/no-vote round rewards route to a configured sink.
- `interfaces/`
  - `IGeneralizedTCR`, `IArbitrator`, `IArbitrable`, `ISubmissionDepositStrategy`, etc.
- `strategies/`
  - `EscrowSubmissionDepositStrategy`: default escrow/bond semantics.
  - `PrizePoolSubmissionDepositStrategy`: forwards accepted submissions to a prize pool.
- `library/TCRRounds.sol`
  - Fee contribution accounting and reward withdrawals.
- `utils/ArbitrationCostExtraData.sol`
  - Encodes arbitration cost snapshots into arbitrator extra data.

## Lifecycle flows

### 1) Register an item (happy path)
1. `addItem(itemData)` submits a registration request.
2. Requester deposits `submissionBaseDeposit + arbitrationCost`. If a submission deposit strategy is active, the base deposit is collected separately and excluded from the Round accounting.
3. If no one challenges before `challengePeriodDuration`, call `executeRequest`.
4. Item becomes `Registered` and hooks fire.

### 2) Remove an item
1. `removeItem(itemID, evidence)` submits a clearing request.
2. Requester deposits `removalBaseDeposit + arbitrationCost`.
3. If unchallenged, `executeRequest` removes the item.

### 3) Challenge and dispute
1. `challengeRequest(itemID, evidence)` within the challenge period.
2. Challenger funds their side with `challengeBaseDeposit + arbitrationCost`.
3. `ERC20VotesArbitrator` creates a dispute and runs commit/reveal voting.
4. Arbitrator calls `rule(disputeID, ruling)`; TCR resolves and updates status.
5. Contributors can withdraw fees/rewards via `withdrawFeesAndRewards`.

### 4) Dispute timeout
If the dispute is solved but not executed and `disputeTimeout` is enabled, anyone can call `executeRequestTimeout` after the timeout window.

## Deposits, fees, and rewards

- **Base deposits** are configured separately for submission, removal, and their challenges.
- **Arbitration cost** is fetched from the arbitrator and snapshotted into `arbitratorExtraData` at request time.
- **Rounds** track requester/challenger funding. The winning side gets fee rewards proportional to contributions.
- Use `getTotalCosts()` to estimate total funding required for each action.

### Submission deposit strategies
By default, `submissionBaseDeposit` is part of the request round accounting. If a submission deposit strategy is set, registration deposits are handled separately and can be:

- **Held** (bond remains locked in the TCR), or
- **Transferred** (sent to a recipient on resolution).

Strategies are called with a gas cap. Invalid or unsafe strategy output falls back to a safe default policy. An invariant is enforced: if the item ends `Absent`, the submission deposit cannot remain locked.

Current implementations:

- `EscrowSubmissionDepositStrategy`
  - Accepted registration: keep bond locked.
  - Rejected registration: transfer to challenger (or refund requester).
  - Successful removal: transfer to remover (or manager if self-removal).
- `PrizePoolSubmissionDepositStrategy`
  - Accepted registration: transfer to a prize pool address.
  - Rejected registration: transfer to challenger (or refund requester).

## Arbitrator expectations

The TCR enforces two constraints on the arbitrator:

- **Token match:** the arbitrator's voting token must be the same ERC20 used for deposits.
- **Arbitrable match:** the arbitrator must be configured to point at this TCR as the arbitrable contract.

The arbitrator implements commit/reveal voting with `votingDelay`, `votingPeriod`, and `revealPeriod`. Disputes are funded in the voting token, not ETH.

## Governance and immutability

- **Arbitrator + arbitrator extra data** are deployment-configured and immutable after initialization.
- **Challenge period** is deployment-configured and init-only.
- **Governor address** is initialization-only (no runtime governor-rotation setter).
- **Registration/clearing meta-evidence URIs** are deployment-configured and immutable after initialization.
- Deployment-time BudgetTCR meta-evidence should be content-addressed (IPFS/Arweave URI or raw CID/txid string).
- `GeneralizedTCR` and `ERC20VotesArbitrator` expose no upgrade path.
- `withdrawRewardsForInvalidRound` sends unresolved/no-vote round funds to `invalidRoundRewardSink` instead of any privileged owner address.

## Evidence and meta-evidence

Registration and clearing requests emit Kleros-style evidence events. Meta evidence URIs are stored separately for registration and clearing, and remain fixed after initialization.

## Integration notes

- Tokens must be ERC20Votes-compatible and standard (no fee-on-transfer, rebasing, or blacklisting).
- `itemID` defaults to `keccak256(itemData)` but can be customized in derived contracts.
- Override `_verifyItemData` to enforce schema rules.
- Use `_onItemRegistered` and `_onItemRemoved` for post-resolution hooks.

## Development

From the repo root:

```sh
forge build
forge test -vvv
```

## License

See the repository root for licensing details.

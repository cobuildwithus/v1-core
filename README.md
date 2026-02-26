# Cobuild Protocol

Cobuild Protocol provides the onchain primitives used by Cobuild's allocation systems. This repo currently ships the
generalized TCR (Token Curated Registry) and an ERC20-votes arbitrator used to curate participant sets and resolve
disputes for Cobuild products like Flows, Rounds, and Reaction Markets.

## How this fits the Cobuild stack

Cobuild's allocation primitives are designed to route capital toward real work using market and community signals:

- **Flows**: always-on streaming grants. A curated list of builders receives continuous payouts from a shared budget.
  Eligibility is maintained by a TCR where anyone can challenge a builder by staking tokens; disputes are resolved by
  token-holder vote.
- **Rounds**: in-feed quadratic funding for open competitions. Builders post work on social platforms; LLM pairwise
  ranking and quadratically weighted engagement drive allocation of a round's budget.
- **Reaction Markets**: engagement-driven micro-purchases. Likes, comments, and follows trigger small buys that route
  capital directly to creators and provide bottom-up signal for Flows and Rounds.

Offchain services handle content ingestion, ranking, and UX. These contracts handle deposits, staking, curation, and
arbitration.

## Contracts

- `GeneralizedTCR`: request/challenge flow for curating lists, deposits and fee tracking, and dispute integration.
- `ERC20VotesArbitrator`: commit-reveal voting arbitration using an ERC20Votes token; used by the TCR.

## Docs

Docs and demos: `docs.co.build`

## Setup

```shell
git submodule update --init --recursive
```

## Build

```shell
forge build
```

## Test

```shell
forge test
```

## Static analysis

Install Slither locally with `pipx install slither-analyzer`, then run:

```shell
pnpm -s slither
```

## Agent commit helper

Use `scripts/committer` for selective commits from agent sessions:

```shell
scripts/committer "chore: concise summary" path/to/file1 path/to/file2
```

Behavior:
- Commits only the exact file paths you pass (no `.` or directory paths).
- Enforces Conventional Commit messages by default.
- Rejects empty commit messages.
- Rejects paths under `lib/**`.
- Uses per-file lock files to prevent concurrent agent commits from racing on the same paths.
- If a lock is stale, rerun with `--force`.
- If you truly need a non-conventional message, pass `--allow-non-conventional` (or set `COMMITTER_ALLOW_NON_CONVENTIONAL=1`).

## ChatGPT browser review launcher

Use the Oracle wrapper script to package a zip and open ChatGPT browser mode with Pro model + extended thinking defaults:

```shell
pnpm -s review:gpt
```

Default behavior (`pnpm -s review:gpt`) is managed remote Chrome mode with upload-only prompt:
- packages a ZIP
- attaches it
- sends a minimal placeholder prompt (`.`) with no preset text
- launches/reuses managed remote Chrome (`~/.oracle/remote-chrome`) and connects via DevTools

Useful variants:

```shell
# only run the security preset
pnpm -s review:gpt --preset security

# shorthand positional preset (same as --preset incentives)
pnpm review:gpt incentives

# run multiple presets
pnpm -s review:gpt --preset security,grief-vectors,incentives

# inspect generated command without launching
pnpm -s review:gpt --dry-run
```

Preset templates live under `scripts/chatgpt-review-presets/`.
Need advanced Oracle flags anyway? pass them through after `--`, for example:

```shell
pnpm -s review:gpt incentives -- --debug
```

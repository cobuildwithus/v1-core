# Completion Note

- Completed: 2026-03-09
- Resulting PR(s): none
- Follow-up items: none.

# Exec Plan: Round Non-Slashing Cleanup

Date: 2026-03-09
Owner: Codex
Status: Completed

## Goal

Remove the round-level slashing configuration surface so round deployments clearly use stake-vault voting without advertising unsupported juror slashing.

## Scope

- Remove round-only slash config fields from `RoundFactory` deployment config.
- Update round-related tests/helpers/call sites to the reduced config shape.
- Update architecture/reference docs to state that round arbitrators are non-slashing by design.

## Non-Goals

- No changes to `ERC20VotesArbitrator` generic slashing behavior.
- No changes to budget TCR or allocation-mechanism arbitrator authorization/slashing semantics.
- No new router authorization flow for round arbitrators.

## Risks / Invariants

- Preserve round stake-vault voting and budget-scoped vote weighting.
- Keep all call sites compiling in one change set after the config shape change.
- Treat the cleanup as a hard cutover since there are no live deployments.

## Verification

- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

## Progress Log

- 2026-03-09: Claimed scope in the coordination ledger and opened this plan.
- 2026-03-09: Removed round slash knobs from `RoundFactory.ArbitratorConfig` and hardcoded round arbitrators to non-slashing deployment params.
- 2026-03-09: Updated round deployment/integration tests to the reduced config shape.
- 2026-03-09: Added a regression for legacy longer-encoded `deployForBudget` payloads to prove removed slash fields are ignored and rounds remain non-slashing.
- 2026-03-09: Updated architecture/reference docs to state that round arbitrators keep stake-vault voting but are not router-authorized slashers.
- 2026-03-09: `pnpm -s verify:required` passed on the final diff.
- 2026-03-09: `pnpm -s lint:solidity:warnings` matched the warnings baseline.

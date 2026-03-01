# Juror Slashing Incentives + Wiring Simplification

Status: completed
Created: 2026-02-25
Updated: 2026-02-25

## Goal

Make juror slashing operational and incentive-aligned with minimal control-surface complexity:
- clear, explicit treasury path to set stake-vault `jurorSlasher` once,
- configurable slash severity (default 50 bps),
- configurable slash caller bounty (default 1%, hard cap 5%) with immediate payout split.

## Scope

- In scope:
  - Goal treasury explicit slasher configuration entrypoint.
  - Goal treasury authority semantics update to meaningful external authority for configuration.
  - Arbitrator slash config parameters (slash bps + caller bounty bps) with caps/defaults and validation.
  - Slash payout split between caller bounty and reward escrow remainder.
  - Factory and tests/mocks updates for new arbitrator params/plumbing.
- Out of scope:
  - `lib/**` changes.
  - broader governance/permission model refactor beyond slasher setup path.

## Constraints

- Preserve one-time slasher binding at stake vault.
- Keep non-stake-vault mode behavior unchanged.
- Maintain conservative ruling logic unchanged.
- Follow completion workflow passes before handoff.

## Acceptance criteria

- Deployers can configure juror slasher through an explicit treasury function.
- Slash bps is configurable with default 50 bps.
- Caller bounty bps is configurable with default 1% and enforced max 5%.
- `slashVoter` pays caller bounty immediately and routes remainder to reward escrow.
- Updated tests cover new config bounds/defaults and payout split.

## Progress log

- 2026-02-25: Claimed coordination ledger and drafted implementation plan.
- 2026-02-25: Implemented configurable slash+bounty params and payout split in `ERC20VotesArbitrator`; wired factory initialization propagation; added authority-gated goal treasury slasher configuration.
- 2026-02-25: Updated factory guard to only auto-configure juror slasher when treasury authority equals factory, preserving deploy safety for non-factory authorities.
- 2026-02-25: Expanded tests/mocks for new init/config surfaces and slashing behavior; required verification gate passed (`pnpm -s verify:required`).

## Open risks

- Existing mixed-branch test failures in unrelated flow suites may block full repo verification; report separately if encountered.

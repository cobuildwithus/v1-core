# Incentive-Compatible Success Finalization (No Exclusion Timing Game)

## Goal
Keep winner-only rewards while removing the payoff from delaying competitor budget resolution near goal finalization.

## Scope
- `GoalTreasury`: defer success-path reward escrow finalization until tracked budgets are resolved.
- `BudgetStakeLedger`: remove `resolvedAt <= goalFinalizedAt` as a success-eligibility condition.
- `BudgetTreasury`: make post-deadline pending-assertion resolution progress via permissionless `sync()`.
- Update tests and architecture/spec docs to match behavior.

## Invariants
- Goal success state transition remains immediate when assertion is truthful.
- Reward point accrual cutoff remains based on goal success timestamp and budget funding/removal cutoffs.
- Winner-only payout semantics remain intact.
- Budget outcome set cannot be strategically held open forever by participants under functioning oracle settlement:
  - only one pending assertion at a time,
  - no new assertion registration at/after deadline,
  - settled pending assertions become permissionlessly finalizable via `sync()`.

## Validation
- Targeted `forge test` runs for modified suites.
- Required gate: `pnpm -s verify:required`.

## Notes
- This change intentionally avoids adding new public control surfaces, grace periods, or optional timeout knobs.

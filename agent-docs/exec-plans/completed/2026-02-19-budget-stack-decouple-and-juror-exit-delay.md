# Budget Stack Decouple And Juror Exit Delay

Status: completed
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Remove nonce-coupled budget stack linking in `BudgetTCRDeployments`.
- Enforce juror exit delay from `max(requestedAt, goalResolvedAt)`.

## Success criteria

- Budget stack deploy path no longer depends on CREATE nonce prediction.
- `GoalStakeVault.finalizeJurorExit` requires at least `JUROR_EXIT_DELAY` after goal resolution when resolution occurs after exit request.
- Baseline verification passes: `forge build -q`, `pnpm -s test:lite`.

## Scope

- In scope:
  - `src/tcr/library/BudgetTCRDeployments.sol`
  - `src/allocation-strategies/BudgetStakeStrategy.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/goals/GoalStakeVault.sol`
  - `test/BudgetTCRDeployments.t.sol`
  - `test/goals/BudgetStakeStrategy.t.sol`
  - `test/goals/GoalStakeVault.t.sol`
- Out of scope:
  - Budget-ledger scalability redesign
  - Reward-points slashing semantics redesign
  - Forced budget terminalization policy changes

## Decisions

- Use temporary-manager anchor wiring for budget stack setup instead of nonce-predicted treasury address.
- Keep `GoalStakeVault.goalTreasury` immutable and satisfy auth/resolution checks through manager proxy `owner()`/`resolved()` views.
- Keep `BudgetStakeStrategy.budgetTreasury` immutable and resolve effective ledger key via optional `budgetTreasury()` proxy read.

## Progress log

- 2026-02-19: Reworked temporary manager to anchor stake vault/strategy to manager address and expose `budgetTreasury` + proxy views.
- 2026-02-19: Relaxed `BudgetTreasury` constructor validation to allow manager-proxy stake-vault wiring (`goalTreasury == msg.sender` when deployer is contract code).
- 2026-02-19: Updated `GoalStakeVault.finalizeJurorExit` delay gate to use `max(requestedAt, goalResolvedAt)`.
- 2026-02-19: Added/updated tests for nonce-decoupled deployment, proxy strategy lookup, and post-resolution exit delay.
- 2026-02-19: Updated architecture/reference docs for new stack-linking model.

## Verification

- `forge build -q`
- `pnpm -s test:lite`

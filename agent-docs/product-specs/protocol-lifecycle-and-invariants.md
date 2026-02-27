# Protocol Lifecycle and Invariants

## Scope

This spec captures stable lifecycle and behavior contracts across Flow, goals/treasury, and TCR/arbitrator modules.

## Lifecycle Contracts

### Flow lifecycle

- Flows initialize via `CustomFlow.initialize` -> `Flow.__Flow_init`.
- Deployment-time flow knobs are init-only:
  - `flowImpl`, `managerRewardPoolFlowRatePercent`,
    `managerRewardPool`, and `allocationPipeline`.
  - Runtime mutator entrypoints for these knobs are removed.
- Flow authority is split and explicit:
  - `recipientAdmin` governs recipient lifecycle and metadata updates.
  - `flowOperator`/`parent` govern flow-rate mutation.
  - `sweeper` governs held SuperToken sweep.
- Child flow creation via `addFlowRecipient(...)` requires explicit child-role inputs (`recipientAdmin`, `flowOperator`, `sweeper`) at creation time.
- Allocation updates must pass previous-state snapshot/commit validation and strategy allocation checks.
- Allocation-ledger-driven child sync and treasury-driven flow-rate synchronization are part of runtime safety.

### Goal/Budget lifecycle

- Goal and budget treasuries start in funding state, then activate or finalize based on thresholds and deadlines.
- `sync()` is the permissionless best-next-action entrypoint:
  - `Funding`: activate when threshold is met, otherwise expire once windows elapse.
  - `Active`: sync flow-rate while time remains; at/after deadline:
    - goal treasuries resolve pending assertions deterministically (`Succeeded` when truthful, `Expired` when false/invalid, else remain active with zero target flow),
    - budget treasuries open a one-time post-deadline reassert grace when the first pending assertion settles false/invalid; if grace elapses without a new pending assertion (or the grace reassert settles false/invalid), state transitions to `Expired`.
  - Terminal states: no-op.
- Goal active flow-rate targeting is spend-pattern based (linear pattern locked today):
  - raw linear target is `treasuryBalance / timeRemaining`,
  - when the linear target is currently buffer-affordable, sync applies a proactive buffer-derived liquidation-horizon cap before write attempts,
  - write-time fallback ladder remains active on reverts.
- Budget active flow-rate targeting is parent-member-rate based:
  - raw budget target is `parentFlow.getMemberFlowRate(address(budgetFlow))` clamped at `>= 0`,
  - unsolicited third-party inbound streams to the budget flow must not increase budget target rate.
- Manual failure is budget-only and controller-gated (`resolveFailure`), with no goal manual-failure entrypoint.
- Goal terminal states are `Succeeded` and `Expired`; resolved-false or invalid post-deadline success assertions finalize to `Expired`.
- Success transitions are assertion-backed:
  - immutable `successResolver` controls assertion registration/clearing,
  - goal `resolveSuccess` is success-resolver-only and requires an active pending truthful assertion id,
  - budget `resolveSuccess` is success-resolver-only and requires an active pending truthful assertion id.
- Budget listing oracle config is hash-only:
  - `oracleConfig.oracleSpecHash` and `oracleConfig.assertionPolicyHash` must both be non-zero.
- Budget success assertion registration is funding-window gated (no registration before `fundingDeadline`).
- Policy C deadline behavior:
  - goal success assertions must be initiated pre-deadline,
  - budget treasuries allow one post-deadline reassert during active reassert grace after a late false-settled pending assertion,
  - success can finalize post-deadline when assertion was initiated pre-deadline, or for budgets via the one-time post-deadline grace reassert.
- Pending assertions block active-state terminalization races only while unresolved.
- Accepted budget removals use activation-locked split semantics:
  - pre-activation removal disables budget success resolution and makes the budget success-ineligible,
  - post-activation removal stops forward spend/funding but keeps reward-history eligibility; such budgets remain
    success-eligible only if they later resolve terminal `Succeeded`.
- Finalization is state-first and non-bricking:
  - terminal state/timestamp are committed before external settlement side effects,
  - flow stop, residual settlement, reward-escrow finalize, and stake-vault marking are best-effort during finalize and permissionlessly retryable via `retryTerminalSideEffects`,
  - stake-vault resolution remains permissionlessly recoverable through `markGoalResolved()` once treasury reports resolved.
- Goal success state remains immediate, but reward escrow success-finalization is deferred until tracked budgets resolve and is then permissionlessly retryable via terminal-side-effect retries.
- Budget scoring cutoff is exogenous per tracked budget:
  - raw matured stake-time accrual runs until
    `min(goal success timestamp, budget fundingDeadline, budget activation timestamp, budget removal timestamp)`,
  - budget activation timestamp (`activatedAt`) is written on permissionless `sync()` when funding transitions to active (keeper-timing dependent),
  - payout points are window-normalized (`raw matured stake-time / scoring-window seconds`), where scoring window starts at budget registration time,
  - maturation/warmup is derived from scoring-window length (`window / 10`, clamped to `[1 second, 30 days]`),
  - budget `resolvedAt` no longer truncates point accrual.
- Terminal residual handling remains callable after finalization (`GoalTreasury.settleLateResidual`, `BudgetTreasury.settleLateResidualToParent`) to absorb late inflows without stranded value.
- Failed escrow sweep policy is no-reward: goal sweep burns via `goalRevnetId`, cobuild sweep burns via immutable `cobuildRevnetId` (seeded from `goalRevnetId`).

### TCR/arbitration lifecycle

- Request/challenge/dispute/timeout transitions are explicit and should preserve dispute accounting and status semantics.
- Arbitrator token/arbitrable compatibility is a hard precondition.

## Behavioral Guarantees

- Access-control and governance boundaries are explicit and test-backed.
- Funds-transfer paths must remain deterministic and fail-safe.
- External hooks and strategies should not silently invalidate core invariants.

## Breaking-Change Policy

Treat as breaking for integrators when changing:
- interface shapes (`src/interfaces/**`, `src/tcr/interfaces/**`),
- lifecycle/state-machine semantics,
- role/permission paths,
- error/event semantics consumed by external systems.

Document such changes in architecture docs and execution plans.

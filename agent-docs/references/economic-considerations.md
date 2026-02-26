# Economic Considerations

This note tracks protocol-level incentive risks that are economically rational under some token-holder profiles, even when contracts behave as designed.

## Open / Unsolved

### Late-Stage Budget-Clear Griefing (Zero-Points Success) [Open]

### Scenario

A wealthy actor funds or influences a goal, waits until allocators have done most of the work, then pushes synchronized budget removals/challenges close to goal success finalization. If enough budgets are removed or fail by cutoff, successful-point totals can collapse to zero.

### Why it matters

When goal success finalizes with `totalPointsSnapshot == 0`, stakers have no reward denominator and cannot claim reward payouts from the success snapshot path. This can create a "work happened, but stakers earned nothing" outcome.

### Mechanism path (high level)

1. Budgets are challenged/cleared through Budget TCR lifecycle.
2. Removed budgets are detached from goal-flow recipient/ledger paths and success resolution is disabled for those budget treasuries.
3. Goal success finalization snapshots successful budget points.
4. If no successful points remain, reward claims are zeroed by snapshot math.
5. Remaining escrow assets can be swept through terminal no-reward handling.

### Preconditions

- Attacker can repeatedly fund challenges (or coordinate challengers).
- Defender participation is weak or slow in dispute windows.
- Budget removals/failures can be finalized before goal success cutoff.
- Attacker's portfolio preferences make "deny rewards" rational (for example, preferring scarcity/burn effects over staker payouts).

### Impact

- Staker payout confidence degrades near deadline.
- Rational allocators may de-risk away from long-horizon work.
- Governance can drift toward challenge-capital concentration.

### Monitoring signals

- Spikes in Budget TCR challenges shortly before budget/goal deadlines.
- Clusters of removals against high-stake or near-success budgets.
- Rising ratio of challenged listings vs. successfully finalized listings late in goal lifecycle.

### Mitigation directions

- Add end-of-lifecycle anti-grief windows (for example, delayed-effect removals near cutoff).
- Preserve some reward eligibility for budgets with accrued stake-time before late removal.
- Route zero-points success residuals to a neutral sink/rollover instead of strategic burn.
- Increase late-window challenge cost dynamically.
- Improve operational liveness for honest finalization/defense paths.

### UMA Dispute-Latency Delay on Pending Success Assertions [Open]

### Scenario

A budget appears mostly complete. A success assertion is registered near the end of the funding/deadline window, then intentionally disputed (including potential self-dispute if oracle rules permit, or coordinated dispute via a second address). The assertion remains unsettled while the dispute process runs, delaying budget terminalization and potentially downstream reward finalization.

### Why it matters

Even with winner-only payout design, this creates a grief window where a motivated actor can delay competitor payout realization without changing the final truthful outcome.

### Mechanism path (high level)

1. A pending success assertion exists for a budget before deadline.
2. At/after deadline, treasury sync checks assertion state.
3. If assertion is still unsettled, treasury remains `Active` and flow target is driven to zero.
4. Budget remains unresolved until oracle settlement is available and someone calls permissionless progression.
5. If this budget is tracked by a successful goal, goal reward escrow success-finalization can remain deferred while tracked budgets are unresolved.

### Timing envelope

- Undisputed path: roughly bounded by configured `successAssertionLiveness`.
- Disputed path: no protocol-side hard upper bound; delay is bounded only by external oracle/escalation settlement latency and operational liveness of follow-up calls.

### Current constraints already present

- Only one pending success assertion is allowed at a time.
- No new success assertion can be registered at/after budget deadline.
- Once assertion is settled, any caller can progress treasury finalization.
- Resolver/oracle read failures fail closed to terminal false/expired outcomes.

### Residual risk

- If oracle state remains readable but unsettled, there is no in-protocol timeout auto-expiring the pending assertion.
- Budget controller has `disableSuccessResolution` as an escape hatch, but goal-level success path has no equivalent forced-timeout override.

## Solved or Partially Mitigated

### Deadline-Window Exclusion and "Keep Open Forever" Griefing [Partially Mitigated]

### Scenario

In a pro-rata winner pool, an actor can profit by reducing other winners' eligible points. A straightforward strategy is to dispute or delay competitor budget success around goal success finalization so competitor budgets miss the reward snapshot.

### Why it matters

If delay is cheap, the system can reward sabotage, not just accurate allocation. A worse variant is trying to keep budgets unresolved indefinitely so reward finalization never completes.

### Current protocol posture (2026-02-25)

- Goal success state can still resolve immediately once success assertion is truthful.
- Success reward escrow finalization is deferred until tracked budgets are resolved, so late truthful budget success is not excluded by `resolvedAt > successAt` timing.
- Budget post-deadline resolution is permissionless via `sync()`:
  - settled truthful assertion finalizes `Succeeded`,
  - settled false/invalid assertion finalizes `Expired`,
  - only genuinely unsettled assertions keep the budget open.
- A new success assertion cannot be registered at/after budget deadline, and only one pending assertion is allowed at a time.

### Incentive implication

Under functioning oracle settlement, participants cannot keep the system open forever by cycling disputes or re-opening new assertions after deadline. Delay can at most extend to the pending assertion's unsettled period.

### Residual operational risk

- Liveness still depends on someone calling permissionless progression paths (`sync()` and, for goals, `retryTerminalSideEffects()`).
- Very large tracked-budget sets still require multiple permissionless `finalizeStep` / retry calls to complete escrow settlement, even though the goal-side O(n) "all budgets resolved" precheck was removed from the success finalization trigger path.

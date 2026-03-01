# Economic Considerations

This note tracks protocol-level incentive risks that are economically rational under some token-holder profiles, even when contracts behave as designed.

## Open / Unsolved

### Late-Stage Budget-Clear Griefing (Coverage Shock) [Open]

### Scenario

A wealthy actor funds or influences a goal, waits until allocators have established underwriting coverage, then pushes synchronized budget removals/challenges near late lifecycle windows. If enough budgets are removed or failed in a short window, effective insured capacity and underwriting distribution can shift abruptly.

### Why it matters

Even without a reward-points subsystem, late coordinated removals can still:

- reduce useful budget execution windows,
- force rapid reallocation/re-coverage behavior,
- increase operational pressure on keepers to complete terminalization and slash settlement.

### Mechanism path (high level)

1. Budgets are challenged/cleared through Budget TCR lifecycle.
2. Removed budgets are detached from goal-flow recipient/ledger paths and may disable budget success resolution (pre-activation branch).
3. Goal coverage shape and downstream budget underwriting obligations shift abruptly.
4. Keepers/participants must process terminalization and caller-scoped underwriter withdrawal preparation under tighter time pressure.

### Preconditions

- Attacker can repeatedly fund challenges (or coordinate challengers).
- Defender participation is weak or slow in dispute windows.
- Removals/failures cluster near high-sensitivity lifecycle windows.

### Impact

- Coverage continuity degrades under concentrated challenge capital.
- Allocators/underwriters face increased timing uncertainty near deadlines.
- Governance can drift toward challenge-capital concentration.

### Monitoring signals

- Spikes in Budget TCR challenges shortly before budget/goal deadlines.
- Clusters of removals against high-stake or high-throughput budgets.
- Rising ratio of late challenged listings vs. successfully finalized listings.

### Mitigation directions

- Add anti-grief timing windows for removal effectiveness near terminal cutoffs.
- Increase late-window challenge costs dynamically.
- Strengthen keeper automation and explicit operator runbooks for terminalization + slash settlement retries.

### UMA Dispute-Latency Delay on Pending Success Assertions [Open]

### Scenario

A budget appears mostly complete. A success assertion is registered near deadline, then intentionally disputed (including potential coordinated dispute). The assertion remains unsettled while dispute process runs, delaying budget terminalization and downstream operations.

### Why it matters

Even with hard-cut reward removal, a motivated actor can still delay:

- budget terminal state availability,
- post-resolution operational workflows,
- underwriter withdrawal preparation completion for affected budgets.

### Mechanism path (high level)

1. A pending success assertion exists for a budget before deadline.
2. At/after deadline, treasury sync checks assertion state.
3. If assertion is still unsettled, treasury remains `Active` with target flow driven toward zero.
4. Budget remains unresolved until oracle settlement and permissionless progression calls complete.

### Timing envelope

- Undisputed path: roughly bounded by configured `successAssertionLiveness`.
- Disputed path: no protocol-side hard upper bound; delay is bounded by external oracle/escalation settlement latency and operator liveness.

### Current constraints already present

- Only one pending success assertion is allowed at a time.
- No new success assertion can be registered at/after budget deadline except explicit one-time grace policy.
- Once assertion is settled, any caller can progress treasury finalization.
- Resolver/oracle read failures fail closed to terminal false/expired outcomes.

### Residual risk

- If oracle state remains readable but unsettled, there is no in-protocol timeout that force-expires an unresolved pending assertion.

## Solved or Partially Mitigated

### Deadline-Window Exclusion and "Keep Open Forever" Griefing [Partially Mitigated]

### Scenario

A participant attempts to delay competitor budget success around deadline windows or keep budgets unresolved indefinitely by cycling disputes/assertions.

### Current protocol posture (2026-03-01)

- Goal success is assertion-backed and can still resolve immediately once truthful.
- Budget progression after deadline is permissionless via `sync()` and resolver finalization callbacks.
- A new success assertion cannot be repeatedly registered after deadline outside the one-time grace path.
- Only one pending success assertion is allowed at a time.

### Incentive implication

Under functioning oracle settlement, participants cannot keep the system open forever by cycling post-deadline assertions. Delay can at most extend to unsettled oracle windows plus operational lag.

### Residual operational risk

- Liveness still depends on someone calling permissionless progression paths (`sync()`, `retryTerminalSideEffects()`, and slash/forward retry paths where needed).

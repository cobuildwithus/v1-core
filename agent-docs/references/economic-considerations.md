# Economic Considerations

This note tracks protocol-level incentive risks that are economically rational under some token-holder profiles, even when contracts behave as designed.

## Open / Unsolved

### Late-Stage Budget-Clear Griefing (Coverage Shock) [Open]

### Scenario

A wealthy actor funds or influences a goal, waits until allocators have established underwriting coverage, then pushes synchronized budget delist/challenge actions near late lifecycle windows. If enough budgets are delisted or failed in a short window, effective insured capacity and underwriting distribution can shift abruptly.

### Why it matters

Even without a reward-points subsystem, late coordinated delist actions can still:

- reduce useful budget execution windows,
- force rapid reallocation/re-coverage behavior,
- increase operational pressure on keepers to complete terminalization and slash settlement.

### Mechanism path (high level)

1. Budgets are challenged/cleared through Budget TCR lifecycle.
2. Delisted budgets are detached from goal-flow recipient/ledger paths and may disable budget success resolution (pre-activation branch).
3. Goal coverage shape and downstream budget underwriting obligations shift abruptly.
4. Keepers/participants must process terminalization and caller-scoped underwriter withdrawal preparation under tighter time pressure.

### Preconditions

- Attacker can repeatedly fund challenges (or coordinate challengers).
- Defender participation is weak or slow in dispute windows.
- Delist/failure events cluster near high-sensitivity lifecycle windows.

### Impact

- Coverage continuity degrades under concentrated challenge capital.
- Allocators/underwriters face increased timing uncertainty near deadlines.
- Governance can drift toward challenge-capital concentration.

### Monitoring signals

- Spikes in Budget TCR challenges shortly before budget/goal deadlines.
- Clusters of delist actions against high-stake or high-throughput budgets.
- Rising ratio of late challenged listings vs. successfully finalized listings.

### Mitigation directions

- Add anti-grief timing windows for delist effectiveness near terminal cutoffs.
- Increase late-window challenge costs dynamically.
- Strengthen keeper automation and explicit operator runbooks for terminalization + slash settlement retries.

### Registered-Budget Growth Exit Tax on Underwriter Withdrawals [Acknowledged / Open]

### Scenario

An actor repeatedly activates and removes budgets for a goal. `BudgetStakeLedger` retains an append-only historical
`registeredBudgets` list, so removed budgets still increase withdrawal-preparation work forever.

### Why it matters

`StakeVault.withdrawGoal`/`withdrawCobuild` require caller-scoped completion of
`prepareUnderwriterWithdrawal(maxBudgets)`, and preparation iterates registered budgets by index. Even stakers with no
budget exposure pay work proportional to total historical registrations.

### Mechanism path (high level)

1. Budget registrations append to `registeredBudgets`; removals do not shrink history.
2. After goal resolution, each caller must advance `prepareUnderwriterWithdrawal` cursor to `registeredBudgetCount`.
3. Exit cost is O(total historical registered budgets), not O(caller exposure set).

### Measured profile (2026-03-04, local GoalFactory full-stack harness)

- Sampled prepare gas growth: `100 -> 1,082,511`, `800 -> 8,367,263`, `1,600 -> 16,882,466`, `3,200 -> 34,520,361`.
- One-shot prepare at 5,000 registered budgets: `55,351,248` gas.
- Max budgets processed per prepare call in this profile:
  - under 15M cap: `1,402`,
  - under 30M cap: `2,754`.

### 16M-cap operational math (conservative)

Using the 15M measured bound as a conservative Base-like caller cap proxy:

- `prepareCalls ~= ceil(registeredBudgetCount / 1,402)`
- 5,000 budgets -> 4 prepare transactions before withdrawal.
- 10,000 budgets -> 8 prepare transactions before withdrawal.
- 50,000 budgets -> 36 prepare transactions before withdrawal.

This does not strictly hard-lock funds, but it creates a monotonic, attacker-amplifiable exit tax.

### Mitigation directions

- Track per-underwriter budgets-with-exposure and prepare only that sparse set.
- Add `prepareUnderwriterWithdrawalFor(address)` so keepers can advance cursor work for users (optional bounty).
- Add non-refundable per-activation fee or partial bond burn on self-removal to internalize registry-growth externality.

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

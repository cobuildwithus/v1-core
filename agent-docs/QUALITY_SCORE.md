# Quality Score

Snapshot date: 2026-02-26

Scoring rubric:
- `5`: strong guardrails + tests/docs + enforced CI checks
- `4`: good guardrails with minor documented gaps
- `3`: acceptable baseline with clear follow-up needed
- `2`: fragile/high regression risk
- `1`: no reliable guardrails

| Area | Score (1-5) | Evidence | Next follow-up |
| --- | --- | --- | --- |
| Flow module architecture clarity | 4 | `Flow.sol` + `library/**` + expanded flow test suites are well segmented. | Keep flow reference maps in sync with strategy/child-sync changes. |
| Goal/Budget treasury lifecycle quality | 4 | `GoalTreasury`, `BudgetTreasury`, `GoalStakeVault`, `RewardEscrow`, and hook contracts define explicit state paths. | Add explicit lifecycle matrix snapshots per release in docs. |
| TCR/arbitrator lifecycle safety | 4 | TCR and arbitrator modules have broad scenario coverage and invariants. | Keep arbitration timeout/economics docs aligned with parameter updates. |
| Upgrade/storage safety posture | 3 | Upgradeable modules use dedicated storage contracts and upgrade patterns. | Add regular storage-layout diff checks to process docs. |
| Access control and callback boundaries | 3 | Role modifiers and callback entrypoints are explicit in core modules. | Continue hardening and documenting callback trust assumptions. |
| Test and CI coverage posture | 4 | Foundry build, required invariant lane (`FOUNDRY_PROFILE=ci` with `profile.ci.invariant runs=64/depth=128`), coverage gate (`lines>=85`, `branches>=85`), strict size gate policy (no exemptions), and Slither workflow present. | Keep required invariant intensity and PR runtime balanced as suite size grows. |
| Agent-doc enforceability | 4 | Drift + gardening scripts and workflow automation exist. | Keep references and ownership/cadence fields current. |

## Top Risk Register

1. Drift between fast-moving protocol code and architecture/reference docs.
2. Subtle lifecycle regressions across treasury finalization and stake/reward interactions.
3. Hidden coupling between flow child-sync behavior and allocation update patterns.

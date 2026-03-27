---
description: Final completion audit for regressions, correctness, and security
action: thorough review
---

You are performing a final audit of completed changes. Use full diff/context and inspect all modified files plus directly affected call paths.

Runtime expectation:

- This audit may take 5 to 10 minutes on a non-trivial diff.
- Work methodically instead of rushing to a shallow answer.
- Parent agent: allow the run to continue and do not cancel it early unless there is clear evidence the audit is stuck or off scope.

Preflight (required):
- Read `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` before review.
- Honor any explicit exclusive/refactor notes from the ledger; otherwise work carefully on top of active rows without reverting adjacent edits.

Review for:
- functional/behavioral regressions
- edge cases and failure-mode handling
- incorrect assumptions and invariant breaks
- security/correctness risks
- unexpected interface or state-transition changes
- test gaps for newly introduced risk

Output requirements:
- Return findings ordered by severity (`high`, `medium`, `low`).
- For each finding include: `severity`, `file:line`, `issue`, `impact`, `recommended fix`.
- Include an "Open questions / assumptions" section when uncertainty remains.
- If no findings exist, state that explicitly and list residual risk areas (if any).

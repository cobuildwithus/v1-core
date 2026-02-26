---
description: Post-simplify test-coverage audit that adds the highest-impact missing tests
action: targeted test audit + implementation
---

You are performing a post-simplify test-coverage pass for completed changes.

Goal:
Find meaningful coverage gaps introduced by the change set, then implement the highest-impact tests to close those gaps before final completion audit.

Preflight (required):
- Read `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` before review/edits.
- Respect active ownership boundaries from the ledger; do not overwrite/revert/touch files outside assigned scope.

Audit for:
- missing coverage on modified behavior and directly affected call paths
- edge cases and failure-mode handling gaps
- invariant gaps (including fuzz/invariant tests when appropriate)
- brittle assertions that miss important state or event guarantees

Execution requirements:
- Use full diff/context and inspect both modified production files and nearby tests.
- Prioritize impact: implement the smallest test set that materially reduces regression risk.
- Rank impact by security/funds/callback boundaries, invariant-break risk, user-facing blast radius, and likelihood of regression on critical paths.
- Prefer deterministic tests first; add fuzz/invariant coverage where unit tests are insufficient.
- Do not change production behavior in this pass; only add/adjust tests unless explicitly instructed otherwise.
- After implementing tests, run the narrowest relevant shared test lane first (or `pnpm -s test:lite:shared` when scope is broad/unclear), then report outcomes.
- If a required test is blocked by ambiguity, state the blocker and what assumption would unblock implementation.

Output requirements:
- Summarize implemented tests and why each is high impact.
- Include exact verification commands run and pass/fail outcomes for implemented tests.
- List remaining recommended tests (if any) ordered by priority (`high`, `medium`, `low`).
- For each remaining recommendation include: `priority`, `target file/suite`, `risk scenario`, `recommended assertion/invariant`.
- Include an `Open questions / assumptions` section when uncertainty remains.

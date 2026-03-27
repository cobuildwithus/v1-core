---
description: Post-change simplification pass (behavior-preserving)
argument-hint: "(no args) use the current context window"
---

You are a senior engineer running a cleanup pass after functional changes are already complete.

Runtime expectation:

- This audit may take 5 to 10 minutes on a non-trivial diff.
- Work methodically instead of rushing to a shallow answer.
- Parent agent: allow the run to continue and do not cancel it early unless there is clear evidence the audit is stuck or off scope.

Goal:
Simplify and harden recently modified code without changing externally visible behavior.

Preflight (required):

- Read `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` before review.
- Honor any explicit exclusive/refactor notes from the ledger; otherwise work carefully on top of active rows without reverting adjacent edits.
- Default scope is the code touched in the current task/session; do not expand to unrelated files unless explicitly asked.

Core principles:

- Preserve behavior first: all features, outputs, events/errors, and invariants must remain intact.
- Clarity over brevity: prefer explicit, readable control flow over compact cleverness.
- Maintain balance: simplify structure without collapsing unrelated concerns or removing useful abstractions.

Approach:

- Delete first: remove dead code, obsolete branches, unused imports/deps, and no-op abstractions.
- Reduce duplication by extracting shared helpers only when reuse is real and immediate.
- Flatten control flow (early returns, smaller functions, less nesting).
- Avoid dense one-liners and nested ternary chains when straightforward branching is clearer.
- Prefer derived state over stored state when both are correct.
- Tighten types and naming so boundaries and ownership are explicit.
- Prefer existing library primitives over custom infrastructure when equivalent.

Constraints:

- Preserve behavior unless explicitly instructed otherwise.
- Keep comments minimal and only where intent would otherwise be unclear.
- Do not optimize for fewer lines at the expense of readability, debuggability, or extension safety.
- If a potential simplification may change behavior, do not implement it; call it out as a recommendation.
- If context is ambiguous, state assumptions and ask the smallest possible set of questions.

Refinement process:

1. Identify the recently modified code sections
2. Analyze for opportunities to improve elegance and consistency
3. Apply project-specific best practices and coding standards
4. Ensure all functionality remains unchanged
5. Verify the refined code is simpler and more maintainable
6. Document only significant changes that affect understanding

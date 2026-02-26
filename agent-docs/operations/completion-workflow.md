# Completion Workflow

Last verified: 2026-02-24

## Sequence

Docs-only shortcut: for docs-only changes (`*.md`, `agent-docs/**`, no `.sol` edits), skip required-check reruns and do not run `forge build`/`pnpm -s build` unless the user explicitly asks for verification.

Non-docs rule: for any change that touches production code or tests, all three subagent passes below are mandatory before final handoff.

1. After implementation is complete, run a simplification pass using `agent-docs/prompts/simplify.md`.
2. If required checks are queued/running (`pnpm -s verify:required` or queue variants), proceed with simplify/coverage/completion-audit work while waiting; do not idle on queue wait.
3. Apply behavior-preserving simplifications from that pass.
4. Run a test-coverage audit pass using `agent-docs/prompts/test-coverage-audit.md` with full change context.
5. The coverage-audit subagent should implement the highest-impact missing tests it identifies (especially edge cases, failure modes, and invariants) before handoff.
6. Re-run required checks after the simplify + test-coverage sequence (even if no new tests were added).
7. Run a completion audit using `agent-docs/prompts/task-finish-review.md` with full change context.
8. Final handoff remains gated on green required checks; completing audits does not waive verification requirements.
9. Do not skip these subagent passes unless the user explicitly instructs to skip them for that turn.

## Coordination Ledger (Always Required)

- Before any coding work (including subagent audit passes that may propose or apply edits), add an active row to `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`.
- Keep the row updated when scope/symbol intent changes.
- In every subagent handoff packet, require the subagent to read and honor current ledger ownership before reviewing/editing files.
- Remove your row immediately when the task is complete or abandoned.

## Audit Handoff Packet

When using a fresh subagent for coverage or completion audits, provide:

- What changed and why (behavior-level summary, not just filenames).
- Expected invariants and assumptions that must still hold.
- Links to active execution-plan docs under `agent-docs/exec-plans/active/` (when present).
- Verification evidence already run (commands plus pass/fail outcomes).
- Current git worktree context (relevant modified files, known unrelated dirty paths, and review scope boundaries).
- Explicit instruction to read `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` and avoid touching files owned by other active entries.

Instruct the reviewer to use the handoff packet plus current `git diff` and call-path inspection, not diff-only inference.

## Shared Worktree Safety

- During simplify, test-coverage-audit, and completion-audit subagent passes, never overwrite, discard, or revert existing worktree edits (including unrelated dirty files).
- Do not use reset/checkout-style cleanup commands to "prepare" files for these passes.
- If a suggested change collides with pre-existing edits, leave the file untouched and escalate in handoff notes instead of force-applying.

## Severity Policy

- Prefer a fresh subagent for coverage and completion audits; only fall back to same-agent audit when subagent execution is unavailable.
- Resolve all high-severity findings before handoff; if any are deferred, document risk, rationale, and follow-up owner.

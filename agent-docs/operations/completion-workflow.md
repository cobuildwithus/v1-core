# Completion Workflow

Last verified: 2026-03-13

## Sequence

Docs-only shortcut: for docs-only changes (`*.md`, `agent-docs/**`, no `.sol` edits), skip required-check reruns and do not run `forge build`/`pnpm -s build` unless the user explicitly asks for verification.

Non-docs rule: for any change that touches production code or tests, all three subagent passes below are mandatory before final handoff.

1. After implementation is complete, run a simplification pass using `agent-docs/prompts/simplify.md`.
2. If required checks are running (`pnpm -s verify:required`), proceed with simplify/coverage/completion-audit work while waiting; do not idle.
3. Apply behavior-preserving simplifications from that pass.
4. Run a test-coverage audit pass using `agent-docs/prompts/test-coverage-audit.md` with full change context.
5. The coverage-audit subagent should implement the highest-impact missing tests it identifies (especially edge cases, failure modes, and invariants) before handoff.
6. Re-run required checks after the simplify + test-coverage sequence (even if no new tests were added).
7. For any change that touches `.sol`, run `pnpm -s build:sizes` before final handoff.
8. If `build:sizes` reports an over-limit contract, or your diff materially increases pressure on a near-limit contract, reduce size before handoff. Prefer the existing `Flow.sol` pattern: move heavy helper logic into existing libraries with `external` or `public` helpers when a current boundary fits, and only add a new library when reuse is not a clean option.
9. Run a completion audit using `agent-docs/prompts/task-finish-review.md` with full change context.
10. Final handoff must report required-check results; green required checks remain the default completion bar, and for Solidity-affecting work a passing `build:sizes` run is also part of completion.
11. If a required check fails for a credibly unrelated pre-existing reason, commit your exact touched files and hand off with the failing command, failing target, and why your diff did not cause it. If you cannot defend that separation, treat the failure as blocking.
12. Do not skip these subagent passes unless the user explicitly instructs to skip them for that turn.

## Coordination Ledger (Always Required)

- Before any coding work (including subagent audit passes that may propose or apply edits), add an active row to `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`.
- Treat the row as an active-work notice by default, not a hard lock.
- Overlap is allowed when agents stay within their declared scope, read the current file state first, and preserve adjacent edits.
- Mark a row as exclusive in `Dependency Notes` only when overlap is unsafe, such as a broad refactor or a delicate cross-cutting rewrite.
- Keep the row updated when scope/symbol intent or exclusivity expectations change.
- In every subagent handoff packet, require the subagent to read the ledger, honor any explicit exclusive/refactor notes, and otherwise work carefully on top of overlapping rows.
- Remove your row immediately when the task is complete or abandoned.

## Audit Handoff Packet

When using a fresh subagent for coverage or completion audits, provide:

- What changed and why (behavior-level summary, not just filenames).
- Expected invariants and assumptions that must still hold.
- Links to active execution-plan docs under `agent-docs/exec-plans/active/` (when present).
- Verification evidence already run (commands plus pass/fail outcomes).
- Current git worktree context (relevant modified files, known unrelated dirty paths, and review scope boundaries).
- Explicit instruction to read `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`, honor any explicit exclusive/refactor notes, and otherwise work carefully on top of overlapping rows.

Instruct the reviewer to use the handoff packet plus current `git diff` and call-path inspection, not diff-only inference.

## Shared Worktree Safety

- During simplify, test-coverage-audit, and completion-audit subagent passes, never overwrite, discard, or revert existing worktree edits (including unrelated dirty files).
- Do not use reset/checkout-style cleanup commands to "prepare" files for these passes.
- If a suggested change collides with pre-existing edits, leave the file untouched and escalate in handoff notes instead of force-applying.

## Severity Policy

- Prefer a fresh subagent for coverage and completion audits; only fall back to same-agent audit when subagent execution is unavailable.
- Resolve all high-severity findings before handoff; if any are deferred, document risk, rationale, and follow-up owner.

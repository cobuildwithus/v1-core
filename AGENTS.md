# AGENTS.md

## Purpose

This file is the routing map for agent work in this repository.
Detailed guidance lives in `agent-docs/`.

## Precedence

1. Explicit user instruction in the current chat turn.
2. `Hard Rules (Non-Negotiable)` in this file.
3. Other sections in this file.
4. Detailed process docs under `agent-docs/**`.

If instructions still conflict after applying this order, ask the user before acting.

## Read Order

1. `agent-docs/index.md`
2. `ARCHITECTURE.md`
3. `agent-docs/cobuild-protocol-architecture.md`
4. `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
5. `agent-docs/RELIABILITY.md`
6. `agent-docs/SECURITY.md`
7. `agent-docs/references/module-boundary-map.md`
8. `agent-docs/references/goal-funding-and-reward-map.md`
9. `agent-docs/references/testing-ci-map.md`
10. `agent-docs/operations/verification-and-runtime.md`
11. `agent-docs/operations/completion-workflow.md`
12. `AGENT_MEMORY.md` (historical context when needed)

## Hard Rules (Non-Negotiable)

- Never modify files under `lib/**`.
- Never change submodule contents under `lib/`.
- Never overwrite, revert, delete, or rewrite other people's changes under any circumstances without explicit confirmation from the user in this chat.
- Run completion workflow subagent passes before final handoff for non-trivial code changes: `simplify` -> `test-coverage-audit` -> `task-finish-review` (see `agent-docs/operations/completion-workflow.md`).
- Docs-only changes must skip completion workflow subagent passes (`simplify`, `test-coverage-audit`, `task-finish-review`) unless the user explicitly asks to run them.
- Other clearly small, low-risk changes (for example comment-only edits or narrowly scoped mechanical updates with no behavior change) may skip completion workflow subagent passes.
- Always keep `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` current for every coding task (single-agent and multi-agent): claim scope before first edit, list planned symbol add/rename/delete work, and remove your entry when done.
- Any spawned subagent that may review or edit code must check `COORDINATION_LEDGER.md` first and must not overwrite/revert work owned by another active entry.
- Release ownership is user-operated: do not run release/version-bump/publish flows (including tag-push release triggers) unless the user explicitly asks in the current turn.
- Never lower CI coverage minimums without explicit user approval in the current chat; keep both `COVERAGE_LINES_MIN` and `COVERAGE_BRANCHES_MIN` at `85` or higher.
- If a task appears to require a `lib/**` change, stop and ask the user for explicit approval and an alternative approach first.
- Use canonical external interfaces: import from local `lib/**` packages when available; otherwise copy exact canonical interface files from upstream (do not invent minimal/approximate variants).
- Do not inline helper interfaces or externally consumed structs inside concrete contracts; define/reuse them in `src/interfaces/**` (for example `IFlow`/`ICustomFlow`) and import from there.
- In protocol lifecycle code, prefer typed interface calls over low-level selector `.call` helpers; when best-effort behavior is required, use typed `try/catch` with explicit failure observability.
- Do not add internal/private production helpers solely to satisfy tests. Test-specific composition belongs in `test/**` harnesses/mocks, or tests should exercise existing production entry points.
- Historical docs are immutable snapshots. Do not edit past/historical plan docs (especially under `agent-docs/exec-plans/completed/`); create a new plan for new work instead.
- Treat upgrade auth, funds flow, and cross-contract callback paths as security-critical.
- Assume trusted core deployments for this repo: avoid adding compatibility shims that silently continue when required selectors/interfaces are missing; prefer strict interface calls and explicit failures.
- Use a hard cutover approach and never implement backward compatibility unless explicitly asked.
- Deployment status (as of 2026-02-20): there are no live protocol deployments yet.
- Until live deployments exist, do not preserve legacy/backward-compatibility code paths by default (aliases, migration-only scaffolding, append-only storage layering solely for upgrades). Prefer simplification.
- As soon as a first live deployment exists, update this note immediately and restore strict upgrade/storage/backward-compatibility requirements.
- Keep this file short and route-oriented; keep durable detail in `agent-docs/`.

## How To Work

- Before starting implementation, run a quick assumptions check: if any high-impact assumption is unclear (scope, security, invariants, external dependencies, or deployment behavior), ask the user to clarify first.
- Do not block on low-impact assumptions; proceed with best judgment and call out those assumptions in handoff notes.
- Continue working in the current tree even when unrelated external worktree changes appear.
- Do not pause or block progress solely because the worktree is dirty; treat out-of-scope changes as context unless they conflict with a listed hard rule.
- If you generate temporary files for testing or exploration (for example scratch JSON outputs, archives, or local metadata), remove them before handoff so they are not committed.
- If unrelated breakage appears in files you did not touch, keep working on your scoped changes; only take ownership of fixing it when your edits caused it or the user explicitly asks.
- Do not introduce "break compile now, fix later" phases during shared work.
- Keep `agent-docs/exec-plans/active/COORDINATION_LEDGER.md` current: claim scope before coding, list planned symbol add/rename/delete work, and remove your entry when done.
- When a change can affect compilation (especially interface, signature, or struct changes), update all affected contracts/interfaces/call sites in the same change set so the tree stays compiling.
- For multi-file or high-risk work, add an execution plan in `agent-docs/exec-plans/active/`.
- For architecture-significant code changes, update matching docs in `agent-docs/` and `agent-docs/index.md`.

### Commit and Handoff

- Same-turn task completion = acceptance, unless the user explicitly says `review first` or `do not commit`.
- If you changed files and required checks are green (defined below), you MUST run `scripts/committer "type(scope): summary" path/to/file1 path/to/file2` before sending final handoff.
- Do not end with "ready to commit" or "commit pending"; perform the commit in the same turn.
- Use `scripts/committer` only (no manual `git commit`).
- Agent-authored commit messages should use Conventional Commits (`feat|fix|refactor|build|ci|chore|docs|style|perf|test`).
- If no files changed in the current turn, do not create a commit.
- Commit only exact file paths touched in the current turn.
- `scripts/committer` commits full-file diffs for each listed path (not hunk-level).
- Do not skip commit just because the tree is already dirty.
- If a touched file already had edits, still commit and explicitly note that in handoff.
- On commit failure, report the exact error and retry with the appropriate fix (`--force` for stale lock, rerun after branch moved, fix Conventional Commit message, etc.).

### Required Checks (Decision Matrix)

| Change scope | Required action | Notes |
| --- | --- | --- |
| Docs-only (`*.md`, `agent-docs/**`, no `.sol` edits) | Do not run verification or completion workflow passes by default | Run checks/passes only if the user asks. |
| Non-doc, non-Solidity changes only (no `.sol` edits; for example scripts/tooling/tests) | Skip `pnpm -s verify:required` by default | Run targeted checks only when requested or when the change itself requires them. |
| Any `.sol` file touched | Run `pnpm -s verify:required` before handoff | Required gate for Solidity changes. |
| User explicitly says to skip checks for this turn | Skip checks | User instruction takes precedence for that turn. |

- `pnpm -s verify:required:full` is optional and only required when explicitly requested by the user.
- Use `pnpm -s verify:required:ci` when you explicitly want local parity with the CI invariant lane.

## Quick Commands

- Required Solidity gate (local-fast): `pnpm -s verify:required`
- CI-parity Solidity gate (includes invariants): `pnpm -s verify:required:ci`
- Full gate (when requested): `pnpm -s verify:required:full`
- Follow running full gate logs: `pnpm -s verify:full:tail`
- Commit tool: `scripts/committer "type(scope): summary" path/to/file1 path/to/file2`

## Detailed Operations

- Verification lanes, queue behavior, and runtime guardrails: `agent-docs/operations/verification-and-runtime.md`
- Simplify/coverage/completion audit workflow: `agent-docs/operations/completion-workflow.md`

## Notes

- `agent-docs/index.md` is the canonical docs map. Keep it updated whenever docs move or change.

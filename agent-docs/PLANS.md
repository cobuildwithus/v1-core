# Plans

Execution plans are first-class artifacts in this repository.

## Locations

- Active: `agent-docs/exec-plans/active/`
- Completed: `agent-docs/exec-plans/completed/`
- Debt tracker: `agent-docs/exec-plans/tech-debt-tracker.md`

## Lifecycle Scripts

- Create a plan: `bash scripts/open-exec-plan.sh <slug> "<title>"`
- Complete a plan: `bash scripts/close-exec-plan.sh <active-plan-path>`

## When To Create A Plan

Create a plan for multi-file protocol changes, safety-sensitive updates, or cross-domain contract work.

Examples:
- upgrade/storage migrations,
- funds-flow and treasury lifecycle updates,
- flow allocation/rate behavior changes,
- TCR/arbitrator request economics changes,
- CI/process rule changes.

## Plan Quality Bar

A usable plan includes:
- clear goal and success criteria,
- in-scope and out-of-scope boundaries,
- explicit constraints and risks,
- ordered tasks and verification commands,
- decisions captured as they are made.

## Plan and Code Coupling

When architecture-sensitive code changes occur, at least one should be true:
- matching non-generated docs are updated, or
- an active execution plan captures intended follow-up.

Prefer both for complex changes.

## Historical Plan Policy

- Treat historical plans as immutable records.
- Do not edit completed/closed plan files for new changes.
- For new work, create a new active plan and link prior plans as references.

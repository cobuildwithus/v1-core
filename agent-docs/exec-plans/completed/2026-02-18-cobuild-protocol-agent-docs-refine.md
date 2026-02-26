# Cobuild Protocol agent docs and architecture refinement

Status: completed
Created: 2026-02-18
Updated: 2026-02-18

## Goal

- Upgrade protocol docs to agent-first quality: short AGENTS router, concrete architecture/reliability/security docs, durable references, and mechanical drift/gardening enforcement.

## Success criteria

- Core docs and index reflect actual protocol module boundaries and lifecycle invariants.
- Reference maps exist for flow, goals/treasury, tcr/arbitration, and verification workflows.
- Drift/gardening scripts and CI workflows fail on stale/missing doc artifacts.
- Verification commands pass.

## Scope

- In scope:
  - `AGENTS.md`, `ARCHITECTURE.md`
  - `agent-docs/**` docs and references
  - doc-enforcement scripts and CI workflow checks
- Out of scope:
  - protocol behavior changes in `src/**`
  - test behavior changes outside verification execution

## Constraints

- Do not touch `lib/**`.
- Keep statements grounded in actual code paths and tests.
- Avoid modifying unrelated in-progress protocol code changes.

## Tasks

1. Audit protocol modules, interactions, invariants, and test topology.
2. Refine AGENTS/index/architecture/reliability/security/product/quality docs.
3. Add product-spec and internal/external reference packs.
4. Tighten doc drift/gardening and CI checks.
5. Run verification and close plan.

## Decisions

- Added root `ARCHITECTURE.md` while keeping `agent-docs/cobuild-protocol-architecture.md` as detailed architecture map.
- Added reusable plan lifecycle scripts (`scripts/open-exec-plan.sh`, `scripts/close-exec-plan.sh`) to standardize plan handling.
- Enforced doc checks for `.md` plus `agent-docs/references/*-llms.txt` artifacts.

## Verification

- `bash scripts/doc-gardening.sh --fail-on-issues` -> passed (0 issues)
- `bash scripts/check-agent-docs-drift.sh` -> passed
- `forge build -q` -> passed
- `pnpm -s test:lite` -> passed (406 tests)
Completed: 2026-02-18

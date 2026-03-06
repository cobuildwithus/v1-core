# Repo Tools Semver Rollout

Status: completed
Created: 2026-03-06
Updated: 2026-03-06

## Goal

- Replace the local `file:../repo-tools` dependency with published `@cobuild/repo-tools@^0.1.4` without changing runtime behavior.

## Success criteria

- `package.json` and `pnpm-lock.yaml` reference `^0.1.4`.
- Existing repo-tool-backed scripts still resolve through installed package bins.
- Verification covers the final tree state without taking ownership of unrelated Solidity failures.

## Scope

- In scope: `package.json`, `pnpm-lock.yaml`, and required execution-plan lifecycle docs.
- Out of scope: Solidity source, tests, and runtime behavior changes.

## Constraints

- Technical constraints: keep the change limited to dependency resolution and docs/process artifacts.
- Product/process constraints: do not modify or revert unrelated in-flight Solidity work.

## Risks and mitigations

1. Risk: local-file and published-package resolution diverge for repo-tool wrappers.
   Mitigation: run final verification on the final tree state and report any unrelated pre-existing failures separately.

## Tasks

1. Update dependency spec and lockfile.
2. Run required verification for the final tree state.
3. Close the plan and remove the ledger row.

## Decisions

- Keep runtime script entrypoints unchanged; only switch the package source.

## Verification

- `pnpm install --lockfile-only`
- `pnpm -s build`
- `pnpm -s test:lite:fast`

Completed: 2026-03-06

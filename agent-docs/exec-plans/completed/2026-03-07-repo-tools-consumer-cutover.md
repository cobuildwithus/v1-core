# Repo Tools Consumer Cutover

Status: completed
Created: 2026-03-07
Updated: 2026-03-07

## Goal

- Replace the remaining duplicated local audit package script logic with the shared `@cobuild/repo-tools` bin and bump the repo-tools dependency to the new published version.

## Success criteria

- `scripts/package-audit-context.sh` is a thin repo-tools wrapper.
- Protocol-specific audit bundle behavior remains encoded in local config.
- `package.json` and `pnpm-lock.yaml` use the published repo-tools version that contains the new bin.
- Final verification is attempted without disturbing unrelated in-flight Solidity work.

## Scope

- In scope: audit package wrapper/config, package metadata/lockfile, execution-plan docs.
- Out of scope: Solidity runtime behavior.

## Verification

- `pnpm install --lockfile-only`
- `pnpm -s build`
- `pnpm -s test:lite:fast`
Completed: 2026-03-07

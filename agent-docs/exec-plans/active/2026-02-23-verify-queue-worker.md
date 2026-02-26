# Verification Queue Worker and Shared Ledger

## Objective
- Add a simple shared verification queue so parallel agents can request build/test gates without each launching duplicate runs.

## Scope
- `scripts/verify-queue.sh`
- `package.json`
- `agent-docs/references/testing-ci-map.md`

## Plan
1. Add a queue script with request submission, worker batching, wait/status, and markdown ledger output.
2. Batch pending requests by workspace fingerprint and collapse each batch to one verification execution.
3. Add package scripts for easy usage (`verify:queue:*`).
4. Document queue usage in testing/CI map.

## Verification
- `bash -n scripts/verify-queue.sh`
- `pnpm -s verify:queue:status`
- `pnpm -s build`
- `pnpm -s test:lite:shared`

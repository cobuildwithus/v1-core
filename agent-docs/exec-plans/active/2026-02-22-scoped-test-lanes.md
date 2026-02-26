# Scoped Test Lanes for Multi-Agent Work

## Objective
- Reduce CPU contention during multi-agent development by introducing domain-scoped test commands for fast iteration.

## Scope
- `scripts/test-scope.sh`
- `package.json`
- `AGENTS.md`
- `agent-docs/references/testing-ci-map.md`

## Plan
1. Add a scope-aware Foundry test runner that standardizes common domain lanes.
2. Expose stable `pnpm` scripts for TCR, arbitrator, budget-stack, flows, goals, invariants, and shared-machine thread-capped variants.
3. Update agent docs to route iterative validation toward scoped lanes and reserve a single full verification gate for handoff.

## Verification
- `forge build -q`
- `pnpm -s test:lite`

# Community System Floors

Status: completed
Created: 2026-03-10
Updated: 2026-03-10

## Goal

Introduce floor-first community routing so pinned system goals receive guaranteed treasury-directed funding before discretionary explicit-route or historical/backlog routing.

## Why

- Current community routing has only one pool: explicit selected routes update observed history and all non-explicit flows defer into historical backlog.
- `CommunityGoalRegistry` already distinguishes system goals at the registry layer, but that distinction has no downstream funding effect.
- Maintainer/security upkeep should be baseline community allocation, not dependent on discretionary donor routing history.

## Scope

- Extend `CommunityGoalRegistry` system-goal metadata with floor ppm accounting and views for active system routing.
- Enforce a floor-first split in `CobuildSplitHook` before discretionary explicit-route or backlog deferral.
- Route mandatory floor funding to canonical goal treasury beneficiaries instead of payer-selected beneficiaries.
- Keep historical observed volume and backlog scoped to discretionary routing only.
- Add targeted registry, hook, and wrapper integration regressions.
- Update durable architecture/spec/reliability docs for the new two-pool model.

## Out Of Scope

- Dynamic runway-aware floors, adaptive balance-based top-ups, or gauge/voting systems.
- New manager contracts or treasury-side spend-policy changes.
- Changes to `GoalDeploymentRegistry` ownership model.

## Design Constraints

- Sum of active system floors must never exceed `1_000_000` ppm.
- Paused or otherwise unroutable system goals must not brick community routing; their floor share falls back into discretionary remainder.
- Explicit observed routing volume must remain discretionary-only.
- Historical backlog must store discretionary remainder only.
- Preserve current wrapper backlog snapshot semantics and goal-treasury sink behavior for historical routing.
- Do not revert shared in-flight edits in `CobuildSplitHook.sol` or its tests.

## Acceptance Criteria

- Registry exposes active system-route metadata with floor ppm values and enforces total-floor bounds.
- Community split-hook routes system floors first for both pending-route and no-pending-route controller callbacks.
- System-floor routing uses goal treasury beneficiaries and does not mutate historical observed volume.
- Backlog and historical routing operate only on the discretionary remainder.
- Tests cover floor bounds, paused/unroutable fallback, beneficiary behavior, discretionary-only history, and backlog semantics.

## Verification

- Focused Forge suites for community registry, split hook, and wrapper integration.
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`
- Completion workflow passes: `simplify` -> `test-coverage-audit` -> `task-finish-review`

## Outcome

- Parent-side targeted coverage audit found no additional high-impact gaps beyond the added registry, hook, and integration tests.
- Focused suites passed:
  - `forge test --match-path test/tcr/CommunityGoalRegistry.t.sol`
  - `forge test --match-path test/hooks/CobuildSplitHook.t.sol`
  - `forge test --match-path test/juicebox/CobuildPaymentTerminalCoreIntegration.t.sol`
- `pnpm -s lint:solidity:warnings` passed with baseline warnings only.
- `pnpm -s verify:required` still fails in unrelated pre-existing suites outside this routing scope, including BudgetTCR deployment/factory coverage and BudgetStakeLedger coverage tests.

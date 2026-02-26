# BudgetTCR IVotes + factory token refactor

Status: active
Created: 2026-02-19
Updated: 2026-02-19

## Goal

- Complete a full OpenZeppelin v5 migration for this repository and remove v4 usage.
- Refactor BudgetTCR deployment so the voting token is provided by config (no token deployment path in `BudgetTCRFactory`).
- Replace test voting-token usage with OZ v5 `ERC20Votes` helpers and retire the bespoke mintable votes-token path.

## Success criteria

- `remappings.txt` resolves `@openzeppelin/contracts` and `@openzeppelin/contracts-upgradeable` to v5 sources.
- `forge build -q` passes without OZ v4 import/path regressions.
- `pnpm -s test:lite` passes.
- BudgetTCR factory no longer deploys a token and requires caller-provided voting token.
- No production path depends on `BudgetTCRVotesToken`/`BudgetTCRTokenFactory`.

## Scope

- In scope:
- Source + test migrations required for OZ v5 compatibility.
- BudgetTCR factory + interfaces + tests touched by token provisioning changes.
- OZ v5 `ERC20Votes` test token wiring for mint/delegate behavior.
- Out of scope:
- Changes to upstream submodules under `lib/**`.

## Constraints

- Technical constraints:
- Product/process constraints:
- Do not edit `lib/**`.
- Preserve upgradeable storage layout safety where applicable.

## Risks and mitigations

1. Risk: OZ v5 import/API changes break large cross-test surface.
   Mitigation: iterative compile/test cycle with targeted fixes per failure class.
2. Risk: Mixed v4/v5 dependency collisions.
   Mitigation: move canonical remappings to v5 and remove mixed-path assumptions.
3. Risk: Factory interface changes ripple through tests/callers.
   Mitigation: update all call sites and add regression checks.

## Tasks

1. Update dependencies/remappings to OZ v5.
2. Fix compile-time incompatibilities (`ReentrancyGuard` paths, `Ownable` constructors, `SafeERC20`, ERC20Votes overrides).
3. Refactor BudgetTCRFactory to consume a provided voting token.
4. Replace mock voting token usage with OZ v5 `ERC20Votes` helpers for tests.
5. Run full verification and fix regressions until green.

## Decisions

- None yet.

## Verification

- Commands to run:
- Expected outcomes:
- `forge build -q`
- `pnpm -s test:lite`

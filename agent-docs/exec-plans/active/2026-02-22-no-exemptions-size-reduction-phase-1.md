# Exec Plan: No-Exemptions Size Reduction (Phase 1)

Date: 2026-02-22
Owner: Codex
Status: In Progress

## Goal
Start reducing runtime bytecode overages without using size exemptions by:
- removing heavy direct `new` deployment paths from `BudgetTCRFactory`,
- introducing clone-based deployment for BudgetTCR and arbitrator instances,
- reducing `BudgetTCR` runtime overhead enough to clear EIP-170 if feasible in-phase.

## Scope
- `src/tcr/BudgetTCRFactory.sol`
- `src/tcr/BudgetTCR.sol`
- impacted constructor callsites (tests/scripts) for `BudgetTCRFactory`
- any minimal docs references required for constructor/deployment model updates

## Constraints
- Do not modify `lib/**`.
- Keep direct trusted-core deployment semantics (no upgrade proxy deployment path reintroduced for runtime instances).
- Keep existing budget lifecycle/auth invariants unchanged.
- Do not use `SIZE_EXEMPT_CONTRACTS` as a long-term fix.
- Leave unrelated local changes untouched.

## Acceptance criteria
- `BudgetTCRFactory` no longer directly deploys heavy contracts with `new BudgetTCR()` / `new ERC20VotesArbitrator()`.
- Factory deployment path uses predeployed implementation addresses and minimal clones.
- `forge build --sizes --contracts src --skip 'test/**'` shows reduced `BudgetTCRFactory` runtime.
- `forge build -q` and `pnpm -s test:lite` run and results are captured.
- Follow-up delta and remaining over-limit contracts are documented.

## Progress log
- 2026-02-22: Baseline measured with `pnpm -s build:sizes`:
  - `BudgetTCR` +513 bytes over,
  - `BudgetTCRFactory` +16,754 bytes over,
  - `BudgetTCRDeployer` +9,977 bytes over,
  - `BudgetTCROpsFactory` +11,927 bytes over,
  - `CustomFlow` +7,980 bytes over.
- 2026-02-22: Identified root cause in `BudgetTCRFactory`: direct heavy `new` deployments.
- 2026-02-22: Replaced helper-factory constructor deployment path with one `BudgetTCRFactory` that clones:
  - `BudgetTCR`,
  - `ERC20VotesArbitrator`,
  - `BudgetTCRDeployer` (clone-initialized via `initialize(budgetTCR)`),
  - `BudgetTCRValidator`.
- 2026-02-22: Removed `BudgetTCROpsFactory` and `IBudgetTCROpsFactory`.
- 2026-02-22: Current size snapshot (`pnpm -s build:sizes`):
  - `BudgetTCR` runtime `24,570` bytes (margin `+6`),
  - `BudgetTCRFactory` runtime `3,459` bytes (margin `+21,117`),
  - `BudgetTCRDeployer` runtime `16,619` bytes (margin `+7,957`),
  - `CustomFlow` runtime `30,676` bytes (margin `-6,100`).
- 2026-02-22: Removed size-exemption handling (`SIZE_EXEMPT_CONTRACTS`) from CI/workflow paths; size gate now fails hard on any oversized concrete contract.

## Open risks
- Clone-based constructor change may require broad test/script updates.
- `CustomFlow` remains over EIP-170 and currently blocks strict `build:sizes` gate.
- `BudgetTCR` now passes but margin is narrow (`+6` bytes), so follow-up feature additions may reintroduce overage risk.

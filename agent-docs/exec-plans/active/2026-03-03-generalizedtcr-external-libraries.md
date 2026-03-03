# Exec Plan: GeneralizedTCR External Library Extraction

Date: 2026-03-03
Owner: Codex
Status: Completed

## Goal
Reduce inherited TCR runtime pressure by extracting heavy `GeneralizedTCR` internal logic into external libraries, following the same style already used by `Flow.sol` (`FlowPools`, `FlowSets`, etc.).

## Scope
- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/library/GeneralizedTCR*.sol` (new helper libraries)
- `test/GeneralizedTCR*.t.sol` (if behavior adjustments require tests)
- `test/BudgetTCR*.t.sol` (if behavior adjustments require tests)

## Constraints
- Do not modify `lib/**`.
- Preserve TCR lifecycle behavior (request/challenge/dispute/ruling/timeout) exactly.
- Preserve event ordering and revert conditions.
- Do not change storage layout.
- Keep changes isolated to TCR module unless tests require fixture updates.

## Acceptance Criteria
- `GeneralizedTCR` delegates selected heavy paths to external library methods.
- Concrete TCR contracts compile and keep behavior-compatible test outcomes.
- `forge build --sizes --contracts src --skip 'test/**'` shows reduced inherited runtime pressure on TCR concretes.
- `pnpm -s verify:required` passes.

## Open Risks
- Library externalization can subtly alter control flow if event emission or mutation order changes.
- Size reductions may be insufficient alone to bring `BudgetTCR` under EIP-170.

## Progress Log
- 2026-03-03: Added external runtime helper library `src/tcr/library/GeneralizedTCRRuntimeLib.sol`.
- 2026-03-03: Refactored `src/tcr/GeneralizedTCR.sol` to delegate request-open/status transition/deposit-resolution/request-state helpers into the runtime library.
- 2026-03-03: Size snapshot (`pnpm -s build:sizes`) after refactor:
  - `BudgetTCR`: `29,084` -> `28,215` (delta `-869`)
  - `AllocationMechanismTCR`: `22,644` -> `21,583` (delta `-1,061`)
  - `RoundSubmissionTCR`: `15,966` -> `14,994` (delta `-972`)
- 2026-03-03: Required verification gate passed: `pnpm -s verify:required`.

Goal (incl. success criteria):
- Increase `GoalTreasury` runtime headroom beyond the current near-limit state by extracting heavy cold-path logic into Flow-style linked library code.
- Preserve current goal lifecycle, zero-premium underwriter omission, and initializer/runtime behavior.
- End with passing `pnpm -s verify:required`, `pnpm -s lint:solidity:warnings`, and `pnpm -s build:sizes`.

Constraints/Assumptions:
- No `lib/**` edits.
- No user-facing ABI changes unless required for a linked-library boundary.
- Prefer a narrow extraction over broad refactor; cold paths are favored over hot sync paths.
- Shared tree has unrelated dirty generated-doc state; keep it out of scope.

Key decisions:
- Use the `Flow.sol` pattern: `public`/linked library helpers that actually reduce runtime size.
- Target init-time revnet/directory/token validation first because it is large and cold.
- Avoid moving hot-path flow-sync logic unless the first extraction is insufficient.

State:
- Complete.

Done:
- Reviewed repo guidance, size workflow, and `Flow.sol` linked-library pattern.
- Confirmed `GoalTreasury` currently sits at essentially zero runtime headroom.
- Extracted revnet/directory/token/deadline init helpers plus cold burn/directory lookups into `GoalTreasuryRevnetLib`.
- Verified `GoalTreasury` runtime margin improved to 2175 bytes in `pnpm -s build:sizes`.
- Ran focused goal-treasury/underwriting tests, full `pnpm -s verify:required`, and `pnpm -s lint:solidity:warnings`.
- Ran required completion workflow passes: simplify (no worthwhile changes), coverage audit (no additional high-impact tests), task-finish-review attempted twice but timed out.

Now:
- None.

Next:
- None.

Open questions (UNCONFIRMED if needed):
- UNCONFIRMED: final task-finish-review subagent result did not return before handoff despite two waits and one retry; no local or audit-coverage findings remain outstanding.

Working set (files/ids/commands):
- `src/goals/GoalTreasury.sol`
- `src/goals/library/*.sol`
- `test/goals/GoalTreasuryUnderwritingConfigGuard.t.sol`
- `test/goals/UnderwritingIntegration.t.sol`
- `pnpm -s build:sizes`
- `pnpm -s verify:required`
- `pnpm -s lint:solidity:warnings`

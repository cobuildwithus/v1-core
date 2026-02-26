# Budget Reassert Grace (Single-Slot, Minimal Surface)

## Goal
Prevent a late false-settled pending assertion from forcing immediate `Expired` when a budget should still be able to prove success, without introducing multi-assertion tracking or broad new control surfaces.

## Scope
- `src/goals/BudgetTreasury.sol`
- `src/interfaces/IBudgetTreasury.sol`
- `test/goals/BudgetTreasury.t.sol`
- lifecycle/economic docs referencing deadline pending-assertion behavior.

## Design constraints
- Keep one pending assertion per treasury.
- No overwrite/latest-wins behavior.
- No multi-assertion arrays or interface-wide assertion-ID selection semantics.
- No new governance knobs in this patch.
- Preserve post-deadline zero-flow behavior.

## Proposed mechanics
- Add a fixed one-time reassert grace duration constant.
- On post-deadline `sync()`:
  - pending settled truthful => `Succeeded` (unchanged),
  - pending unsettled => remain `Active` with zero flow (unchanged),
  - pending settled false:
    - if grace not yet used, clear pending assertion and activate grace window (no finalize),
    - else finalize `Expired`.
- Also activate the same one-time grace when the resolver clears a post-deadline assertion first
  (`clearSuccessAssertion`) so `resolver.finalize/settleAndFinalize` cannot bypass grace via call ordering.
- While grace window is active, allow `registerSuccessAssertion` even though `block.timestamp >= deadline`.
- Grace window is consumed when a post-deadline reassert is registered.
- If grace window expires with no pending assertion, finalize `Expired`.

## Validation
- Update/extend `BudgetTreasury` tests for:
  - settled-false opens grace rather than immediate expiry,
  - resolver clear-first post-deadline path opens grace and blocks immediate expiry on next `sync()`,
  - post-deadline registration allowed only during active grace,
  - expiry once grace elapses with no new assertion,
  - second settled-false after reassert finalizes `Expired` (no second grace).
- Run required Solidity verification gate.

# Goal

Implement a community-level routing path where a payer can buy into an evergreen community revnet and select pre-approved child goals to fund in one transaction.

# Acceptance criteria

- Add a cloneable/initializable `CobuildSplitHook` that validates controller-only reserved-token split callbacks for a configured community revnet.
- Add a user-facing `CobuildPaymentTerminal` wrapper that accepts native ETH or COBUILD and can seed one-shot per-payment routing.
- Reserved community tokens route into pre-approved child goals when an explicit or default route is available, otherwise remain escrowed for later owner-directed sweep.
- Add targeted unit tests for the wrapper and split hook.
- Update durable architecture/reference docs for the new community routing layer.

# Scope

- `src/interfaces/ICobuildSplitHook.sol`
- `src/hooks/CobuildSplitHook.sol`
- `src/juicebox/CobuildPaymentTerminal.sol`
- Focused unit tests under `test/hooks/` and `test/juicebox/`
- Matching `agent-docs/**` updates

## Out of scope

- Community deployer/factory integration
- Consensus-derived auto-routing or keeper automation
- Goal-side funding-hook behavior changes
- Any changes under `lib/**`

# Constraints

- `JBSplitHookContext` does not provide payer-specific metadata, so per-payment routing must be seeded before the community revnet pay executes.
- Funds-routing and callback boundaries are security-critical; public entrypoint permissions must stay explicit and fail closed.
- The wrapper currently treats `pay(...).metadata` as routing metadata only and forwards blank metadata to the underlying community terminal.
- Direct community pays that bypass the wrapper must either use a configured default route/default beneficiary or remain escrowed.

## Tasks

1. Add the new split-hook interface and implementation with approved-goal registry, pending-route consumption, default-route fallback, and escrow sweep.
2. Add the payment wrapper that converts native ETH to COBUILD when needed, seeds a pending route, pays the community revnet, and verifies route consumption.
3. Add focused unit coverage for explicit route consumption, default/escrow fallback, terminal validation, and revert paths.
4. Update architecture/reference docs for the new community root routing path.
5. Run required verification and completion workflow passes, then commit with `scripts/committer`.

## Verification plan

- Targeted iteration: `forge test --match-path test/hooks/CobuildSplitHook.t.sol`
- Targeted iteration: `forge test --match-path test/juicebox/CobuildPaymentTerminal.t.sol`
- Required gate: `pnpm -s verify:required`
- Required warning baseline: `pnpm -s lint:solidity:warnings`

## Progress log

- 2026-03-10: Opened the execution plan, claimed the task in `COORDINATION_LEDGER.md`, and confirmed the wrapper-plus-split-hook architecture against Juicebox v5 hook boundaries.
- 2026-03-10: Added `ICobuildSplitHook`, `CobuildSplitHook`, and `CobuildPaymentTerminal` with explicit-route seeding, default-route fallback, and escrow sweep behavior.
- 2026-03-10: Added focused hook and wrapper tests covering weighted routing, default routing, escrow behavior, controller/route-setter authorization, constructor validation, and route-consumption enforcement.
- 2026-03-10: Updated architecture/spec/security/reliability/reference docs for the new community routing layer and refreshed generated doc inventory via repo doc tooling.
- 2026-03-10: Required verification completed successfully: targeted forge suites passed, `pnpm -s verify:required` passed, `pnpm -s lint:solidity:warnings` passed, and doc drift/gardening checks passed.
- 2026-03-10: Completion workflow passes were attempted in the required order; the simplify pass yielded one safe cleanup (removing redundant zero-first approval resets), and coverage/final-review fallback was completed locally after spawned audit agents failed to return usable results.

## Open risks

- Root-pay metadata passthrough is intentionally out of scope for this version; the wrapper treats `metadata` as routing-only and forwards blank metadata to the underlying community revnet pay.
- Direct community pays that bypass the wrapper remain dependent on owner-managed default routing or later escrow sweep behavior.
- Community deployer/factory integration remains a follow-up and is not included in this change set.

## Notes

- This pass intentionally keeps the routed portion modeled as the community revnet's reserved-token split, not extra wrapper-side math.
- Future deployment integration can point the community revnet's COBUILD terminal at `CobuildPaymentTerminal` once product wiring is defined.
Status: completed
Updated: 2026-03-09
Completed: 2026-03-09

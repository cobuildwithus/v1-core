# Solidity Best Practices

Last updated: 2026-03-04

## Purpose

This document is the canonical Solidity engineering standard for this repository.
It consolidates rules that were previously spread across `AGENTS.md`, architecture docs, security/reliability docs, lifecycle specs, and deployment notes.

## Scope and precedence

- Applies to all Solidity contracts, libraries, interfaces, scripts, and tests in this repo.
- If guidance conflicts, precedence is:
  1. Explicit user instruction in the active chat.
  2. `AGENTS.md` hard rules.
  3. This document.
  4. Other `agent-docs/**` references.

## Toolchain and dependency policy

1. Forge-first policy:
- Use Foundry/Forge as the primary Solidity toolchain (build, test, coverage, and dependency workflow).
- Solidity dependencies must be installed and managed with `forge install` into `lib/**`.
- Use remappings/canonical imports for Solidity dependencies; do not establish npm/pnpm as the source of truth for Solidity package code.

2. Package boundary policy:
- Never modify files under `lib/**`.
- Never change submodule contents under `lib/` unless explicitly approved by the user in the active chat.

## Clone/proxy and initializer safety

1. Initialization must be atomic for runtime instances:
- For any `Initializable` clone/proxy runtime, deploy and initialize in the same transaction.
- Never expose uninitialized runtime addresses between transactions.
- Never assign roles/funds to uninitialized runtime instances.

2. Initializer primitives:
- Prefer OpenZeppelin `Initializable` with `initializer`/`reinitializer`.
- Use `_disableInitializers()` in implementation constructors.
- If `Initializable` is not used, document the exception and reason (for example strict size constraints) in the execution plan.

3. Immutable/config safety for clones/proxies:
- Never rely on constructor-baked `immutable` values for per-instance configuration in clone/proxy implementations.
- Per-instance config must be initializer-set storage.
- Constructor immutables are only acceptable when they are intentional deployment-wide constants shared by all instances.

## Interfaces, boundaries, and call patterns

1. Interfaces and structs:
- Keep cross-domain dependencies explicit through interfaces.
- Do not inline externally consumed interfaces/structs in concrete contracts; define/reuse in `src/interfaces/**`.
- For external dependencies, use canonical interfaces from `lib/**` or exact upstream copies; do not invent approximate/minimal variants.

2. Call patterns:
- Prefer typed interface calls over low-level `.call` selector dispatch.
- For optional/best-effort integrations, use typed `try/catch` with explicit failure observability.
- For required integrations in trusted-core paths, fail fast on missing/invalid interfaces/selectors.

## Security boundaries and authority

1. Access and authority:
- Keep permission checks explicit on public/external entrypoints.
- Keep role boundaries explicit and unambiguous across Flow/TCR/treasury modules.
- Treat upgrade authorization, funds-routing paths, and callback/strategy boundaries as security-critical.

2. Trusted-core assumptions:
- Do not add compatibility shims/probe fallbacks for required dependencies.
- Use hard cutover behavior by default (no backward-compatibility scaffolding unless explicitly requested).

3. Extension points:
- Treat strategies/callback integrations as untrusted unless explicitly constrained and validated.

## Additional external best practices (web-sourced)

The following additions are sourced from Solidity and OpenZeppelin primary docs and are mandatory in this repo unless explicitly overridden by `AGENTS.md` hard rules or user instruction.

1. Never use `tx.origin` for authorization:
- Authorize with `msg.sender` and explicit role checks only.

2. Assume all on-chain data is public:
- Do not treat `private` state as secret.
- Do not rely on block data/on-chain state for secure randomness without a dedicated randomness protocol.

3. Avoid unbounded storage-dependent loops in state-changing paths:
- Any loop whose iteration count can grow with storage can become a gas-DoS/stall vector.
- If unavoidable, make the operation chunked/retryable and clearly document limits.

4. Prefer pull-based withdrawals over push-based sends:
- Prefer withdrawal/pull-payment patterns over direct `transfer`/`send` payout flows.
- Zero/update internal accounting before external value transfer to reduce reentrancy risk.

5. Separate privileged authority from arbitrary-call proxy behavior:
- If a contract can proxy arbitrary user-supplied calls, do not grant it privileged roles.
- Use an explicit privileged wrapper/controller if needed.

6. Enforce least privilege in access control design:
- Split roles by capability (`mint`, `burn`, admin, executor, etc.) instead of broad god-mode roles.
- Protect top-level admin authority with multisig/DAO/timelock governance where feasible.

7. Treat compiler warnings as actionable security signals:
- Resolve warnings instead of normalizing them.
- Keep compiler/toolchain versions current and review Solidity known-bugs data for pinned versions.

## Lifecycle, accounting, and failure semantics

1. Lifecycle/state-machine behavior:
- Keep transitions explicit and monotonic.
- Avoid ambiguous timestamp/deadline boundary behavior.
- Preserve deterministic lifecycle semantics documented in `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`.

2. Funds and accounting behavior:
- Maintain deterministic and fail-safe funds-transfer behavior.
- Reject inconsistent token/value combinations at ingress.
- Preserve underwriting, stake, and allocation accounting invariants.

3. Failure handling:
- Use fail-closed behavior where accounting integrity requires it.
- Use best-effort + observable + permissionlessly repairable behavior where liveness is prioritized.
- Preserve state-first finalization patterns and retryable terminal side-effect entrypoints.

## Testing and verification expectations

1. Required verification:
- If any `.sol` file is touched, run `pnpm -s verify:required` before handoff.
- Keep regression tests for each bugfix or high-risk behavior change.
- Do not add production-only helpers solely to satisfy tests; use test harnesses/mocks where possible.

2. Coverage and CI posture:
- Do not lower `COVERAGE_LINES_MIN` or `COVERAGE_BRANCHES_MIN` below `85` without explicit user approval.
- Keep high-value suites healthy (`test/flows/**`, `test/goals/**`, `test/GeneralizedTCR*.t.sol`, `test/ERC20VotesArbitrator*.t.sol`, `test/invariant/**`).

## Process and documentation hygiene

1. Coordination and ownership:
- Before coding, add/update an active row in `agent-docs/exec-plans/active/COORDINATION_LEDGER.md`.
- Keep ownership and symbol-change intent current while work is active.

2. Documentation updates:
- For architecture-significant Solidity changes, update matching docs in `agent-docs/**` and `agent-docs/index.md`.
- Treat historical plan docs under `agent-docs/exec-plans/completed/**` as immutable snapshots.

## Source documents consolidated

- `AGENTS.md`
- `ARCHITECTURE.md`
- `agent-docs/cobuild-protocol-architecture.md`
- `agent-docs/product-specs/protocol-lifecycle-and-invariants.md`
- `agent-docs/SECURITY.md`
- `agent-docs/RELIABILITY.md`
- `agent-docs/operations/deployment-notes.md`
- `agent-docs/references/module-boundary-map.md`
- `agent-docs/references/goal-funding-and-reward-map.md`
- `agent-docs/references/testing-ci-map.md`

## External source links for web-sourced additions

- Solidity Security Considerations: https://docs.soliditylang.org/en/latest/security-considerations.html
- Solidity Common Patterns: https://docs.soliditylang.org/en/latest/common-patterns.html
- OpenZeppelin Access Control (v5): https://docs.openzeppelin.com/contracts/5.x/access-control

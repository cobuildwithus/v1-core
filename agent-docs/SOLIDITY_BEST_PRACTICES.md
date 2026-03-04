# Solidity Best Practices

Last updated: 2026-03-04

Canonical Solidity policy for this repo. `AGENTS.md` hard rules take precedence.

## Core rules

1. Forge-first toolchain and dependencies:
- Use Foundry/Forge as the primary Solidity toolchain.
- Install/manage Solidity dependencies with `forge install` into `lib/**`.
- Use remappings/canonical imports for Solidity deps (not npm/pnpm package code as Solidity source-of-truth).

2. Clone/proxy safety:
- Clone/proxy runtimes must be deployed + initialized atomically.
- Use OZ `Initializable` guards and `_disableInitializers()` for implementation instances.
- Never use constructor-baked `immutable` for per-instance clone/proxy config; use initializer-set storage.

3. Interfaces and external calls:
- Keep cross-domain boundaries explicit via interfaces in `src/interfaces/**`.
- Do not invent approximate/minimal external interfaces.
- Prefer typed interface calls over low-level `.call`; use typed `try/catch` only for explicitly optional integrations.

4. Security and authority:
- Keep public entrypoint permission checks explicit.
- Treat upgrade auth, funds routing, and callback/strategy boundaries as security-critical.
- In trusted-core paths, fail fast on required dependency/interface mismatch (no compatibility shims).
- Use hard cutover by default (no backward-compat scaffolding unless explicitly requested).

5. Lifecycle and accounting:
- Preserve explicit/monotonic lifecycle transitions and deterministic accounting semantics.
- Use fail-closed behavior for accounting-critical paths.
- Use best-effort + observable + permissionlessly repairable behavior for liveness-oriented side effects.

6. Testing and verification:
- If any `.sol` file is touched, run `pnpm -s verify:required` before handoff.
- Then run `pnpm -s lint:solidity:warnings` to prevent net-new production lint warnings.
- Add regression tests for bugfixes/high-risk behavior changes.
- Do not add production-only helpers just to satisfy tests.

## 7 external best practices (web-sourced)

1. Never use `tx.origin` for authorization.
2. Assume all on-chain data is public; `private` is not secrecy.
3. Do not use naive on-chain randomness (block variables/state) for secure randomness.
4. Avoid unbounded storage-dependent loops in state-changing paths (or chunk operations explicitly).
5. Prefer pull/withdrawal payment patterns over push payouts.
6. Do not combine privileged roles with arbitrary-call proxy behavior.
7. Enforce least privilege and treat compiler warnings/known-bugs as security signals to resolve.

## External references

- Solidity Security Considerations: https://docs.soliditylang.org/en/latest/security-considerations.html
- Solidity Common Patterns: https://docs.soliditylang.org/en/latest/common-patterns.html
- OpenZeppelin Access Control (v5): https://docs.openzeppelin.com/contracts/5.x/access-control

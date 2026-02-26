# Product Sense

## Protocol Product Intent

- Prioritize correctness, deterministic behavior, and legibility for future agent runs.
- Preserve explicit lifecycle/state semantics for flow, curation, arbitration, treasury, and reward modules.
- Treat governance-facing and participant-facing behavior as stable contracts requiring explicit migration notes when changed.

## User and Integrator Outcomes

1. Flow allocation behavior is auditable and bounded.
- Allocation snapshots/commitments and recipient updates should remain traceable and deterministic.

2. Treasury lifecycle transitions are explicit.
- Funding/active/finalized states should avoid ambiguous transitions.

3. Curation and dispute semantics are stable.
- Request/challenge/dispute/timeout paths must remain predictable for participants and integrators.

4. Reward and stake handling is legible.
- Goal outcomes and claimability behavior should be explicit and test-backed.

## Contract Stability Rules

- Breaking interface or lifecycle changes require product-spec and architecture doc updates.
- Avoid hidden behavior changes in upgrades, role checks, or callback paths.
- Preserve event and error semantics where external tools rely on them.

## Update Triggers

Update this doc when changing:
- lifecycle/state-machine behavior,
- participant-facing economics assumptions,
- role/governance semantics,
- hook/treasury integration outcomes.

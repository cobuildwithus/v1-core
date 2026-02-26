# Security

## Hard Constraints

- Never modify files under `lib/**`.
- Treat upgrade authorization and role boundaries as security-critical.
- Treat funds movement paths (hook -> flow -> treasury/escrow/vault) as security-critical.
- Keep external callback/strategy interactions explicit and bounded.

## Trust Boundaries

1. Role and upgrade boundary
- Manager/governor authority is split across Flow/TCR/treasury modules.
- Flow runtime instances are non-upgradeable and expose no runtime upgrade selector; child flows are deployed as EIP-1167 minimal clones.
- Strategy/TCR/arbitrator runtime modules are direct deployments with no UUPS upgrade entrypoints.
- Budget stack authority model specifics:
  - `BudgetTCR` is deployed as a direct contract instance (no runtime proxy upgrade path).
  - `BudgetTreasury` privileged paths are gated by immutable `controller`, not transferable ownership.

2. Token and funds boundary
- ERC20/SuperToken transfers, stake deposits/withdrawals, and escrow claims are sensitive operations.

3. External protocol boundary
- Superfluid and Bananapus/JBX integrations must preserve expected token and callback semantics.

4. Strategy/callback boundary
- Allocation strategies and submission deposit strategies are extension points and should be treated as untrusted unless explicitly constrained.

## Security-Critical Paths

- `src/Flow.sol`
- `src/library/FlowInitialization.sol`
- `src/library/FlowRates.sol`
- `src/goals/GoalTreasury.sol`
- `src/goals/BudgetTreasury.sol`
- `src/goals/GoalStakeVault.sol`
- `src/goals/RewardEscrow.sol`
- `src/hooks/GoalRevnetSplitHook.sol`
- `src/tcr/GeneralizedTCR.sol`
- `src/tcr/ERC20VotesArbitrator.sol`

## Defensive Rules

- Keep permission checks explicit at public entrypoints.
- Avoid silent behavior changes in upgrade paths.
- Preserve fail-safe behavior on transfer and callback failures.
- Treat timestamp/state-machine edge conditions as high-risk and test accordingly.
- In trusted core deployment paths, require canonical interfaces/selectors explicitly and fail fast if missing.
- Do not add compatibility shims or selector-probe fallbacks for required dependencies; reserve probe/`try` patterns for explicitly optional integrations and document them.

## Escalation

Escalate to humans for:
- upgrade auth model changes,
- funds-routing or treasury finalization semantics changes,
- new external trust boundaries,
- dispute economics and governance-parameter changes,
- security-sensitive callback or strategy extension changes.

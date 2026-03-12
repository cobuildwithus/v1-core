# 2026-03-12 Premium Module Composability Workers

Status: active
Created: 2026-03-12
Updated: 2026-03-12

## Goal

- Make "no premium / no underwriting module" a first-class configuration so managed goals do not need `NullPremiumEscrow` just to satisfy shared wiring.
- Improve protocol composability by representing absence directly with `address(0)` / explicit deployer mode instead of a fake escrow contract.

## Already Done In Tree

- Open-lane `BudgetTCR.syncBudgetTreasuries(...)` already has local terminal-prune fallback with later-sweep idempotence.
- Managed deployment already converges on the generic `IBudgetStackDeployer` / `BudgetTCRDeployer` path.
- The shared deploy seam already uses neutral `IBudgetTreasury.BudgetConfig` plus `RiskModuleInitConfig`.
- `NullPremiumEscrow` is already a shared stateless shim.
- `BudgetSingleAllocatorStrategy` is already cloneable / initializable and its factory already uses clones.
- Spend-policy validation is already centralized and hardened.

This batch must treat those items as fixed inputs and should not reopen them unless required as tiny fallout for the optional-premium cut.

## Design Target

- Managed preset should be able to deploy and operate with no premium module contract at all.
- Open preset should keep real `PremiumEscrow` behavior when premium/slash features are enabled.
- Open preset may also use the same absence mode when both `budgetPremiumPpm == 0` and `budgetSlashPpm == 0`.
- Shared runtime and deployer surfaces should make premium-module absence explicit and observable, not implicit through a no-op shim.

## Non-Goals For This Batch

- Do not fully redesign `IPremiumEscrow` into multiple smaller interfaces in the same pass.
- Do not change real `PremiumEscrow` accounting, claim, slash, or close semantics.
- Do not silently weaken open-preset validation when underwriting is actually configured.
- Do not delete `NullPremiumEscrow` until all live call sites and tests are updated; making it unused is sufficient for the first cut.

## Current Launch Blockers

- The remaining concrete dirty-file blocker in the premium batch target set is:
  - `src/goals/BudgetTreasury.sol`
- That blocks Worker A right now.
- Worker B is structurally independent, but Workers C and D still depend on Worker A's core optional-premium shape, so keep the staged launch order.

## Proposed Hard-Cut Decisions

1. Introduce an explicit deployer absence mode.
- Add `IBudgetStackDeployer.PremiumEscrowMode.None`.
- In `None` mode, `prepareBudgetStack(...)` returns `premiumEscrow = address(0)`.

2. Make budget treasury premium hooks optional.
- Allow `IBudgetTreasury.BudgetConfig.premiumEscrow == address(0)` when the chosen stack mode is "no premium module".
- `BudgetTreasury` should skip escrow close side effects when no premium module is configured.

3. Make manager-reward routing conditional.
- Budget child flows should only wire `managerRewardPool` and nonzero `managerRewardPoolFlowRatePpm` when a premium module is actually present.
- Managed preset should route zero premium ppm with `managerRewardPool = address(0)`.

4. Keep open underwriting fail-fast when enabled.
- If premium/slash features are configured, open deployment must still require a real escrow implementation and the normal router wiring.
- Absence mode is only valid for explicit zero-premium / zero-slash configurations.

5. Treat missing premium module as valid downstream state.
- `IBudgetStackTopologyReader.BudgetStackTopology.premiumEscrow` may be zero.
- `StakeVault` and other consumers must treat zero premium module as "no underwriting side effects exist here", not as malformed wiring.

## Worker Split

### Worker A: Core optional-premium mode

- Suggested worker id:
  - `codex-worker-premium-core`
- Scope:
  - `src/interfaces/IBudgetStackDeployer.sol`
  - `src/interfaces/IBudgetTreasury.sol`
  - `src/goals/BudgetTreasury.sol`
  - `src/tcr/library/BudgetTCRStackDeploymentLib.sol`
  - optional narrow coverage in `test/goals/BudgetTreasury.t.sol`
- Outcome:
  - shared deployer and treasury surfaces can represent no premium module without a shim contract
  - terminal escrow side effects are skipped cleanly when absent

### Worker B: Downstream consumers accept absence

- Suggested worker id:
  - `codex-worker-premium-downstream`
- Scope:
  - `src/goals/StakeVault.sol`
  - `src/interfaces/IBudgetStackTopologyReader.sol`
  - optional narrow coverage in `test/goals/StakeVault.t.sol`
  - optional doc touch-ups in:
    - `ARCHITECTURE.md`
    - `agent-docs/cobuild-protocol-architecture.md`
    - `agent-docs/references/module-boundary-map.md`
    - `agent-docs/references/goal-funding-and-reward-map.md`
- Outcome:
  - zero premium-module topology is treated as valid optional state
  - underwriter preparation only blocks on real premium/slash exposure paths

### Worker C: Managed preset removes fake escrow dependency

- Suggested worker id:
  - `codex-worker-premium-managed`
- Scope:
  - `src/goals/GoalFactory.sol`
  - `src/goals/library/GoalFactoryManagedPresetDeploy.sol`
  - `src/goals/ManagedBudgetController.sol`
  - `src/goals/NullPremiumEscrow.sol` only if it becomes fully unused inside owned scope
  - optional narrow coverage in:
    - `test/goals/ManagedBudgetController.t.sol`
    - `test/BudgetTCRManagedStackDeployments.t.sol`
    - `test/goals/GoalFactoryUnderwritingSlashConfigGuard.t.sol`
- Outcome:
  - managed preset bootstraps with no premium module contract at all
  - managed budget stacks stop creating or sharing `NullPremiumEscrow`

### Worker D: Open/TCR optional-premium validation and wiring

- Suggested worker id:
  - `codex-worker-premium-open`
- Scope:
  - `src/tcr/interfaces/IBudgetTCR.sol`
  - `src/tcr/BudgetTCRFactory.sol`
  - `src/tcr/library/BudgetTCRInitValidation.sol`
  - `src/tcr/library/BudgetTCRStackActions.sol`
  - `src/goals/library/GoalFactoryBudgetTcrDeploy.sol`
  - optional narrow coverage in `test/BudgetTCR.t.sol`
- Outcome:
  - open lane allows explicit no-premium mode only for zero-premium / zero-slash configurations
  - real underwriting mode stays fail-fast and fully wired

## Launch Order

### Batch A: safe parallel start

- Worker B
- Worker A after the `BudgetTreasury` blocker clears

Rationale:
- Worker B can move independently because it stays out of the currently dirty treasury file.
- Worker A still defines the canonical optional-premium core surface, so Workers C and D should wait for it even if Worker B finishes first.

### Batch B: after Worker A lands or parent integrates its core surface

- Worker C
- Worker D

Rationale:
- both depend on the shared optional-premium mode introduced by Worker A
- their write scopes are otherwise disjoint

### Parent integration

- reconcile any shared semantic fallout between Worker B and Workers C/D
- update broader deployment tests that still mention `NullPremiumEscrow`
- decide whether `NullPremiumEscrow` can be deleted immediately or should remain dead until a tiny cleanup pass
- run required Solidity verification:
  - `pnpm -s verify:required`
  - `pnpm -s lint:solidity:warnings`
  - `pnpm -s build:sizes`
- then run completion workflow:
  - `simplify`
  - `test-coverage-audit`
  - `task-finish-review`

## Worker Launch Command

Run from the workspace root after the parent clears launch blockers:

```bash
workspace-docs/bin/codex-workers \
  --profile 4 \
  --sandbox workspace-write \
  --full-auto \
  workspace-docs/codex-worker-prompts/2026-03-12-v1-core-premium-module-batch/1-core-optional-premium.md \
  workspace-docs/codex-worker-prompts/2026-03-12-v1-core-premium-module-batch/2-downstream-optional-premium.md
```

Then Batch B:

```bash
workspace-docs/bin/codex-workers \
  --profile 4 \
  --sandbox workspace-write \
  --full-auto \
  workspace-docs/codex-worker-prompts/2026-03-12-v1-core-premium-module-batch/3-managed-remove-null-dependency.md \
  workspace-docs/codex-worker-prompts/2026-03-12-v1-core-premium-module-batch/4-open-tcr-optional-premium.md
```

## Discussion Points Before Launch

- Whether to allow open preset absence mode immediately for zero-premium / zero-slash configs, or first limit absence mode to managed only.
- Whether `NullPremiumEscrow` should stay in-tree as dead compatibility scaffolding for one turn, or be deleted in the same batch once tests are updated.
- Whether `StakeVault` should treat zero premium module as automatically prepared for withdrawal, or require an additional explicit check on goal underwriting config.

## Recommended Answers

- Allow open preset absence mode immediately, but only for explicit `budgetPremiumPpm == 0 && budgetSlashPpm == 0`.
- Make `NullPremiumEscrow` unused first, then delete it in a tiny follow-up cleanup unless a worker can prove all imports/tests are already owned and updated safely.
- Treat zero premium module as "no underwriting side effects exist here"; do not block withdrawal preparation solely because no escrow contract exists.

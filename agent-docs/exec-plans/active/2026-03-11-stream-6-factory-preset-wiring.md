# 2026-03-11 Stream 6 Factory Preset Wiring

Status: active
Created: 2026-03-11
Updated: 2026-03-11

## Goal

- Make open and managed goals first-class deployable presets from the same `GoalFactory` surface.
- Keep preset choice in deployment-time module selection, not in neutral runtime contracts.

## Acceptance Criteria

- `GoalFactory` supports explicit open vs managed preset deployment.
- Core stack wiring accepts explicit controller/recipient-admin and allocator strategy outputs.
- Open preset still deploys with `StakeVault` as goal allocator and `BudgetTCR` as budget controller.
- Managed preset deploys with `SingleAllocatorStrategy`, `ManagedBudgetController`, no gate policy (`address(0)`), and no premium module (`premiumEscrowImplementation = address(0)` / prepared `premiumEscrow = address(0)`).
- Managed preset keeps `StakeVault` as funding vault and records Safe-owned child recipient-admin config.
- Goal factory regression tests cover both presets.

## Scope

- In scope:
  - goal factory preset selection and deploy bundle wiring
  - core-stack deploy refactor for explicit strategy/controller inputs
  - minimal managed preset deployment modules required to make preset deployment testable
  - targeted tests, scripts, and docs for the new preset entry points
- Out of scope:
  - deep managed controller runtime behavior beyond goal-deploy wiring needs
  - advisory/mechanism TCR work for managed preset
  - `lib/**` changes

## Risks / Seams

- `GoalFactory.sol` and `GoalFactoryCoreStackDeploy.sol` are hot merge-conflict files.
- Stream 2 is concurrently changing the generic controller seam; avoid depending on `IBudgetTCR`-specific runtime behavior where generic controller naming can be used.
- Deployment scripts and tests currently assume `budgetTCR` naming and open-only paths.

## Plan

1. Generalize core-stack deployment inputs so controller/admin and allocator strategy are explicit.
2. Introduce preset selection in `GoalFactory` and split open vs managed bundle deployment.
3. Add minimal managed preset modules/factory needed for deterministic deployment and wiring assertions.
4. Update tests/scripts/docs to reflect preset entry points and generic controller outputs.
5. Run required verification plus completion workflow passes, then remove the ledger entry.

## Final Wiring Entry Points

- Goal deploy entry point:
  - `GoalFactory.deployGoal(DeployParams)`
  - `DeployParams.preset = GoalPreset.Open | GoalPreset.Managed`
  - `DeployParams.managedSafe` is required only for `GoalPreset.Managed`
- Core substrate deployment:
  - `GoalFactoryCoreStackDeploy.deployCoreBase(...)` deploys the shared substrate (`StakeVault`, ledger, pipeline, goal SuperToken)
  - `GoalFactoryCoreStackDeploy.finalizeCoreStack(...)` now accepts explicit `goalAllocatorStrategy`, `budgetController`, and `jurorSlasherAuthority`
- Open preset bundle:
  - `goalAllocatorStrategy = stakeVault`
  - `budgetController = predicted/deployed BudgetTCR`
  - `jurorSlasherAuthority = BudgetTCRFactory`
  - deployed through `GoalFactoryBudgetTcrDeploy.deployBudgetTcrStack(...)`
- Managed preset bundle:
  - bootstrapped through `GoalFactoryManagedPresetDeploy.bootstrapManagedPreset(...)`
  - `goalAllocatorStrategy = SingleAllocatorStrategy`
  - `budgetController = ManagedBudgetController` clone
  - `budgetGatePolicy = address(0)`
  - explicit no-premium wiring via `premiumEscrowImplementation = address(0)`
  - `premiumEscrowImplementation = address(0)`
  - `jurorSlasherAuthority = ManagedBudgetController`
  - controller initialized through `GoalFactoryManagedPresetDeploy.initializeManagedController(...)`
- Deploy script artifact outputs:
  - `goalAllocatorStrategy`
  - `budgetController`

## Follow-on Cleanup

- Replace the temporary `ManagedBudgetControllerStackDeployer` stub with the real managed stack-deployer adapter once Stream 4/5 runtime composition is finalized.
- Once the generic controller naming settles across the repo, rename the `DeployParams.budgetTCR` input bundle to a controller-generic name so open and managed presets stop sharing an open-specific config label.
- If the managed preset starts exposing budget creation through public deployment tooling, add deploy-script/env support for a managed-safe contract address instead of relying on the default open-preset path.

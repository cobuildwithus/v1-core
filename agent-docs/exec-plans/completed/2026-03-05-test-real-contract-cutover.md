# Goal

Replace the highest-impact mock-heavy Solidity tests with more realistic local contract wiring so coverage better matches real budget-stack, treasury/underwriting, invariant, child-sync, and rounds behavior.

# Scope

- `test/BudgetTCR.t.sol`
- `test/BudgetTCRCreditLineGating.t.sol`
- `test/BudgetTCRManagerRewardPoolWiring.t.sol`
- `test/goals/UnderwritingIntegration.t.sol`
- `test/hooks/GoalRevnetSplitHook.t.sol`
- `test/goals/PremiumEscrow.t.sol`
- `test/goals/UnderwriterSlasherRouter.t.sol`
- `test/invariant/TreasuryTerminalLifecycle.invariant.t.sol`
- `test/flows/FlowLedgerChildSyncProperties.t.sol`
- `test/rounds/AllocationMechanismTCR.t.sol`

# Constraints

- Test-only refactor; no intended production/runtime behavior changes.
- Do not touch `lib/**`.
- Preserve existing targeted branch-forcing mocks where they are still the right tool.
- Use real local repo contracts and existing test frameworks/helpers where feasible.
- Keep subagent write ownership disjoint and avoid repo-wide verification inside subagents.

# Acceptance criteria

- Budget-stack credit-line and activation/removal tests rely less on `MockBudgetTCRSystem` and less on `vm.mockCall` for policy-critical paths.
- Goal/underwriting and split-hook tests execute more of the real `GoalTreasury` / `BudgetTreasury` / `PremiumEscrow` / `StakeVault` / router path.
- The terminal lifecycle invariant uses more real flow/treasury plumbing.
- The rounds allocation-mechanism suite uses a more realistic local host/pool path for funding receipt accounting.
- Required checks, completion workflow passes, and commit complete successfully.

# Progress log

- 2026-03-05: Opened plan and claimed work in coordination ledger.
- 2026-03-05: Cut over budget-stack success paths to real `BudgetStakeLedger` / `PremiumEscrow` wiring and added real escrow manager-reward assertions.
- 2026-03-05: Added real lifecycle coverage in `PremiumEscrow.t.sol`, `UnderwriterSlasherRouter.t.sol`, and `UnderwritingIntegration.t.sol`.
- 2026-03-05: Replaced split-hook preset treasury responses with a lifecycle-driven treasury harness and replaced rounds host/pool success-path mocks with local fixtures.
- 2026-03-05: Upgraded `TreasuryTerminalLifecycle.invariant.t.sol` to use a shared super token, real cloned `PremiumEscrow`, and real `BudgetStakeLedger`, then added a budget/escrow terminal-state invariant.
- 2026-03-05: Verification completed: targeted forge suites passed, `pnpm -s verify:required` passed, and `pnpm -s lint:solidity:warnings` matched baseline.

# Open risks

- Shared worktree already has unrelated active rows; avoid overlapping owned files.
- Some recommendations may require new local harness contracts to keep test runtime manageable.
- Residual risk: `test/BudgetTCR.t.sol` remains a shared file with another active row, so this task limited itself to a narrow premium-escrow assertion there.

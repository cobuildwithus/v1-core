# Flow Allocation Ledger Fail-Closed Wiring

## Objective
- Make allocation-ledger behavior explicit for flow allocation checkpointing.
- Preserve no-op behavior when no ledger is configured.
- Fail closed (deterministically) when a ledger is configured but miswired.

## Scope
- `src/Flow.sol`
- `src/flows/CustomFlow.sol`
- `src/interfaces/IFlow.sol`
- `test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`

## Design Notes
- `setAllocationLedger(address)` now validates configured ledgers (non-zero) up front.
- If ledger treasury code is not deployed yet, only ledger+goalTreasury shape is validated at set-time; full treasury wiring is enforced on first checkpoint use.
- CustomFlow checkpoint path now hard-checks configured ledger wiring and no longer silently returns on misconfiguration.
- Single-strategy requirement remains enforced for ledger checkpoint mode.

## Verification
- `forge build -q`
- `forge test --match-path test/flows/CustomFlowRewardEscrowCheckpoint.t.sol`
- `pnpm -s test:lite`

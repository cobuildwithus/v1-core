# UMA Success Resolver (Policy C) for Goal/Budget Treasuries

## Goal
Implement UMA OOv3-based success resolution with one active assertion per treasury, immutable deploy-time success resolver and oracle config, and Policy C semantics (success can finalize after deadline if assertion was initiated pre-deadline).

## Scope
- Add an UMA resolver contract with permissionless `assertSuccess`/`settle`/`finalize`.
- Add immutable `successResolver` + immutable assertion params to `GoalTreasury` and `BudgetTreasury`.
- Gate success assertion lifecycle on treasury side (`registerSuccessAssertion`, pending assertion lock, clear path).
- Enforce "removed budget can never resolve success".
- Pass budget success-resolver/config through BudgetTCR deployment path.
- Keep owner-based failure/terminal controls for budget removal flow.
- Update tests and docs as needed.

## Invariants to Preserve
- One active assertion max per treasury.
- Success remains oracle-mediated and resolver-gated.
- Owner-only failure/force-zero paths remain intact for budget TCR terminalization.
- Pending success assertion blocks competing terminalization races (Policy C safety).
- Removed budgets are permanently ineligible for success.

## Validation
- `forge build -q`
- `pnpm -s test:lite`
- Size check focused on `BudgetTCR` if needed: `forge build --sizes --skip 'test/**' --contracts src/tcr/BudgetTCR.sol`

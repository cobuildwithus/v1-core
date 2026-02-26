Objective:
Perform a focused security audit of the attached repository snapshot.

Review priorities:
- Authorization and privilege boundaries (`onlyOwner`, manager/controller roles, trust assumptions).
- Funds flow correctness (token custody, transfer paths, settlement paths, accounting drift).
- Lifecycle/state-machine safety (invalid transitions, terminal-state handling, deadline edge cases).
- External call safety (callbacks, reentrancy surfaces, unchecked return paths, griefable side effects).
- Interface assumptions (unsafe casts, missing selector/behavior checks, integration mismatches).

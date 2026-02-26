Objective:
Perform a focused security audit of the attached repository snapshot.

Severity policy:
- Report only security issues that are explicitly High or Critical severity.
- Ignore Medium/Low/Informational issues unless they are immediate blockers for High/Critical findings.
- Prioritize exploitable or protocol-breaking defects with clear attacker paths and realistic execution.

Review priorities:
- Authorization and privilege boundaries (`onlyOwner`, manager/controller roles, trust assumptions).
- Funds flow correctness (token custody, transfer paths, settlement paths, accounting drift).
- Lifecycle/state-machine safety (invalid transitions, terminal-state handling, deadline edge cases).
- External call safety (callbacks, reentrancy surfaces, unchecked return paths, griefable side effects).
- Interface assumptions (unsafe casts, missing selector/behavior checks, integration mismatches).

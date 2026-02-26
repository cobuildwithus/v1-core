Objective:
Find concrete bad-code patterns and anti-patterns that hurt correctness, readability, and maintainability.

Review priorities:
- Inconsistent invariants or assumptions between related functions.
- Over-complicated conditionals or duplicated branch logic.
- Error-prone arithmetic/unit handling and unchecked conversions.
- Fragile event/error semantics for integration consumers.
- Missing defensive checks at public entrypoints.
- Hidden coupling across modules and unclear ownership boundaries.
- Ambiguous naming that obscures role or trust assumptions.
- Overloaded functions with mixed responsibilities.
- Magic numbers, implicit units, and weak parameter validation.
- Error handling patterns that hide failures or create silent fallback behavior.
- Test-smell indicators (assertion gaps, fragile fixture setup, low-signal tests).

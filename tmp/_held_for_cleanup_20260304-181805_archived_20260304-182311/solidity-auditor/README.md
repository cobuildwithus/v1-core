# Solidity Auditor

A security agent with a simple mission - findings in minutes, not weeks.

Built for:

- **Solidity devs** who want a security check before every commit
- **Security researchers** looking for fast wins before a manual review
- **Just about anyone** who wants an extra pair of eyes.

Not a substitute for a formal audit - but the check you should never skip.

## Codex Usage

In Codex, invoke this as a skill request in plain language (not a slash command). Include `deep` and `--file-output` tokens when needed.

## Demo

_Portrayed below: finding multiple high-confidence vulnerabilities in a codebase_

![Running solidity-auditor in terminal](../static/skill_pag.gif)

## Usage

```bash
# Scan the full in-scope repo (default)
run solidity-auditor

# Full in-scope repo + adversarial reasoning agent (slower, more thorough)
run solidity-auditor deep

# Review specific file(s)
run solidity-auditor src/Vault.sol
run solidity-auditor src/Vault.sol src/Router.sol

# Write report to a markdown file (terminal-only by default)
run solidity-auditor --file-output
```

## Known Limitations

**Codebase size.** Works best up to ~2,500 lines of Solidity. Past ~5,000 lines, triage accuracy and mid-bundle recall drop noticeably. For large codebases, run per module rather than everything at once.

**What AI misses.** AI is strong at pattern matching — missing access controls, unchecked return values, known reentrancy shapes. It struggles with relational reasoning: multi-transaction state setups, specification/invariant bugs, cross-protocol composability, game-theory attacks, and off-chain assumptions. AI catches what humans forget to check. Humans catch what AI cannot reason about. You need both.

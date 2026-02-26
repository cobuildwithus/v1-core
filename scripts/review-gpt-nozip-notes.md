# Review GPT No-ZIP Size Notes

Date: 2026-02-26

Observed binary-search results in this repo workflow:

- `302,659` bytes: fail
- `263,369` bytes: fail
- `256,596` bytes: fail
- `251,357` bytes: fail
- `250,000` bytes: pass
- `246,118` bytes: pass
- `228,662` bytes: pass
- `149,105` bytes: pass

Current practical cap for this environment appears to be about `250,000` bytes.

Recommended operating target:

- Keep generated payloads at or below `248,000` bytes for safety margin.

Use `scripts/build-nozip-review-prompt.sh` to build capped payloads by profile.

Current thorough two-pass recommendation:

- `comprehensive-a-goals-interfaces`
- `comprehensive-b-flow-tcr` (no swap paths)

Build examples (`review:gpt:nozip`):

- `pnpm -s review:gpt:nozip -- --profile comprehensive-a-goals-interfaces --target-bytes 248000 --out audit-packages/review-gpt-nozip-comprehensive-a-goals-interfaces-final.md`
- `pnpm -s review:gpt:nozip -- --profile comprehensive-b-flow-tcr --target-bytes 248000 --out audit-packages/review-gpt-nozip-comprehensive-b-flow-tcr-final.md`
- `--out` sets the exact output file path instead of using a timestamped default.

Browser-open upload + inline prompt (`review:gpt`) with package-native flags:

- `pnpm -s review:gpt -- --prompt-file audit-packages/review-gpt-nozip-comprehensive-a-goals-interfaces-final.md --preset security`
- `pnpm -s review:gpt -- --prompt-file audit-packages/review-gpt-nozip-comprehensive-b-flow-tcr-final.md --preset security`

Notes:

- `--prompt-file` is provided by `cobuild-review-gpt` (in `review-gpt-cli`), not by the protocol wrapper script.
- If your installed CLI does not show `--prompt-file` in `pnpm exec cobuild-review-gpt --help`, install/update from `../review-gpt-cli` first.
- Repeat `--prompt-file` to combine multiple local markdown payloads in one request when within the model size cap.

#!/usr/bin/env bash

set -euo pipefail

mode="deployable"
if [ "${1:-}" = "--" ]; then
  shift
fi

case "${1:-}" in
  "")
    ;;
  --all)
    mode="all"
    ;;
  --deployable)
    mode="deployable"
    ;;
  -h|--help)
    cat <<'EOF'
Usage: pnpm copy:all-sol [--all|--deployable]

Defaults to --deployable:
  - copies only concrete contract source files under src/
  - additionally includes Flow base + allocation witness libraries:
    src/Flow.sol, src/library/FlowAllocations.sol
  - skips interfaces/libraries/helper-only files
  - excludes generic TCR boilerplate + helper strategy contracts

Use --all for the previous behavior:
  - copies all non-test Solidity files outside lib/
EOF
    exit 0
    ;;
  *)
    echo "Error: unknown option '$1'." >&2
    echo "Run: pnpm copy:all-sol -- --help" >&2
    exit 1
    ;;
esac

if ! command -v pbcopy >/dev/null 2>&1; then
  echo "Error: pbcopy is not available on this system." >&2
  exit 1
fi

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

tmp_candidates="$(mktemp)"
tmp_all="$(mktemp)"
cleanup() {
  rm -f "$tmp_candidates" "$tmp_all"
}
trap cleanup EXIT

if [ "$mode" = "all" ]; then
  find "$ROOT" -path "$ROOT/lib" -prune -o \
    -type d \( -name test -o -name tests \) -prune -o \
    -type f -name "*.sol" ! -name "*.t.sol" -print \
    | sed "s#^$ROOT/##" \
    | sort >"$tmp_candidates"
else
  find "$ROOT/src" -type f -name "*.sol" \
    | sed "s#^$ROOT/##" \
    | sort >"$tmp_candidates"

  while IFS= read -r relpath; do
    case "$relpath" in
      src/tcr/strategies/EscrowSubmissionDepositStrategy.sol|\
      src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol|\
      src/tcr/GeneralizedTCR.sol|\
      src/tcr/ERC20VotesArbitrator.sol|\
      src/tcr/storage/GeneralizedTCRStorageV1.sol|\
      src/tcr/storage/ArbitratorStorageV1.sol)
        continue
        ;;
      src/Flow.sol|\
      src/library/FlowAllocations.sol)
        echo "$relpath" >>"$tmp_all"
        continue
        ;;
    esac

    # Keep only files that declare at least one concrete contract.
    if rg -q '^[[:space:]]*contract[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$ROOT/$relpath"; then
      echo "$relpath" >>"$tmp_all"
    fi
  done <"$tmp_candidates"

  sort -u -o "$tmp_all" "$tmp_all"
fi

if [ "$mode" = "all" ]; then
  cp "$tmp_candidates" "$tmp_all"
fi

count="$(wc -l < "$tmp_all" | tr -d ' ')"
if [ "$count" = "0" ]; then
  echo "No Solidity files matched mode '$mode'."
  exit 0
fi

while IFS= read -r relpath; do
  printf '\n===== %s =====\n' "$relpath"
  cat -- "$ROOT/$relpath"
  printf '\n'
done <"$tmp_all" | pbcopy

echo "Copied contents of $count file(s) to clipboard (mode: $mode)."

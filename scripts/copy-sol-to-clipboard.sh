#!/usr/bin/env bash

set -euo pipefail

mode="changed-non-tests"

usage() {
  cat <<'EOF'
Usage: scripts/copy-sol-to-clipboard.sh [--changed-non-tests|--changed-tests|--changed-all]

Modes:
  --changed-non-tests   Changed/new non-test Solidity files (default)
  --changed-tests       Changed/new Solidity test files only
  --changed-all         All changed/new Solidity files
EOF
}

if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "$#" -gt 1 ]; then
  echo "Error: too many arguments." >&2
  usage >&2
  exit 1
fi

case "${1:-}" in
  "")
    ;;
  --changed-non-tests)
    mode="changed-non-tests"
    ;;
  --changed-tests)
    mode="changed-tests"
    ;;
  --changed-all)
    mode="changed-all"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Error: unknown option '$1'." >&2
    usage >&2
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

tmp_changed="$(mktemp)"
tmp_unique="$(mktemp)"
tmp_filtered="$(mktemp)"

cleanup() {
  rm -f "$tmp_changed" "$tmp_unique" "$tmp_filtered"
}
trap cleanup EXIT

git -C "$ROOT" diff --name-only HEAD -- \
  ':(glob)**/*.sol' \
  ':(exclude,top)lib/**' >"$tmp_changed"

git -C "$ROOT" ls-files -o --exclude-standard -- \
  ':(glob)**/*.sol' \
  ':(exclude,top)lib/**' >>"$tmp_changed"

sort -u "$tmp_changed" | sed '/^$/d' >"$tmp_unique"

case "$mode" in
  changed-tests)
    awk '/(^|\/)test(s)?\// || /\.t\.sol$/' "$tmp_unique" >"$tmp_filtered"
    label="test"
    ;;
  changed-all)
    cp "$tmp_unique" "$tmp_filtered"
    label=""
    ;;
  changed-non-tests)
    awk '!/(^|\/)test(s)?\// && !/\.t\.sol$/' "$tmp_unique" >"$tmp_filtered"
    label="non-test"
    ;;
  *)
    echo "Error: unsupported mode '$mode'." >&2
    exit 1
    ;;
esac

count="$(wc -l < "$tmp_filtered" | tr -d ' ')"
if [ "$count" = "0" ]; then
  if [ -n "$label" ]; then
    echo "No changed Solidity $label files matched your filters."
  else
    echo "No changed Solidity files matched your filters."
  fi
  exit 0
fi

while IFS= read -r relpath; do
  printf '\n===== %s =====\n' "$relpath"
  cat -- "$ROOT/$relpath"
  printf '\n'
done <"$tmp_filtered" | pbcopy

if [ -n "$label" ]; then
  echo "Copied contents of $count $label file(s) to clipboard."
else
  echo "Copied contents of $count file(s) to clipboard."
fi

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

baseline_file="scripts/solidity-lint-warning-baseline.tsv"
exclude_path_re='^(test/|script/|src/mocks/|src/swaps/CobuildSwap\.sol$)'

tmp_log="$(mktemp)"
tmp_actual="$(mktemp)"
tmp_baseline="$(mktemp)"
cleanup() {
  rm -f "$tmp_log" "$tmp_actual" "$tmp_baseline"
}
trap cleanup EXIT

if [[ ! -f "$baseline_file" ]]; then
  echo "Missing baseline file: $baseline_file" >&2
  exit 2
fi

if ! forge build >"$tmp_log" 2>&1; then
  cat "$tmp_log" >&2
  exit 1
fi

awk -v exclude_re="$exclude_path_re" '
  /^warning\[/ {
    code = $0;
    sub(/^warning\[/, "", code);
    sub(/\].*$/, "", code);
    next;
  }
  /▸ / {
    location = $0;
    sub(/^.*▸ /, "", location);
    gsub(/[[:space:]]+$/, "", location);

    file = location;
    sub(/:[0-9]+:[0-9]+$/, "", file);

    if (file ~ exclude_re) next;
    print code "\t" location;
  }
' "$tmp_log" | sort -u >"$tmp_actual"

sort -u "$baseline_file" >"$tmp_baseline"

if cmp -s "$tmp_baseline" "$tmp_actual"; then
  count="$(wc -l < "$tmp_actual" | tr -d ' ')"
  echo "Solidity lint warnings match baseline ($count entries)."
  exit 0
fi

echo "Solidity lint warning baseline mismatch."
echo
echo "Unexpected new warnings:"
comm -13 "$tmp_baseline" "$tmp_actual" || true
echo
echo "Baseline warnings no longer present (update baseline if intentional):"
comm -23 "$tmp_baseline" "$tmp_actual" || true
echo
echo "To refresh baseline intentionally: run"
echo "  awk -v exclude_re='${exclude_path_re}' '/^warning\\[/ {code=\$0; sub(/^warning\\[/, \"\", code); sub(/\\].*$/, \"\", code); next} /▸ / {location=\$0; sub(/^.*▸ /, \"\", location); gsub(/[[:space:]]+$/, \"\", location); file=location; sub(/:[0-9]+:[0-9]+$/, \"\", file); if (file ~ exclude_re) next; print code \"\\t\" location}' /tmp/forge-build.log | sort -u > $baseline_file"
exit 1

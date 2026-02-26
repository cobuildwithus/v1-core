#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp_output="$(mktemp)"
tmp_names="$(mktemp)"
cleanup() {
    rm -f "$tmp_output" "$tmp_names"
}
trap cleanup EXIT

search_pattern() {
    local pattern="$1"
    local target="$2"
    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$target" || true
    else
        if [ -d "$target" ]; then
            grep -R -n -E "$pattern" "$target" || true
        else
            grep -n -E "$pattern" "$target" || true
        fi
    fi
}

# Concrete contracts declared in src/. (Excludes interfaces, libraries, and abstract contracts.)
search_pattern '^[[:space:]]*contract[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' src \
    | sed -E 's/.*contract[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/' \
    | sort -u > "$tmp_names"

set +e
FOUNDRY_DISABLE_NIGHTLY_WARNING="${FOUNDRY_DISABLE_NIGHTLY_WARNING:-1}" \
    forge build --sizes --contracts src --skip 'test/**' > "$tmp_output" 2>&1
status=$?
set -e

set +e
awk -F'\\|' -v names_file="$tmp_names" '
BEGIN {
    while ((getline n < names_file) > 0) keep[n] = 1
    close(names_file)
    printf("%-42s %16s %18s %18s %18s\n", "Contract", "Runtime Size (B)", "Initcode Size (B)", "Runtime Margin (B)", "Initcode Margin (B)")
    print "-----------------------------------------------------------------------------------------------------------------------------"
}
$0 ~ /^\|/ {
    name=$2; gsub(/^ +| +$/, "", name)
    runtime=$3; gsub(/^ +| +$/, "", runtime)
    initcode=$4; gsub(/^ +| +$/, "", initcode)
    rmargin=$5; gsub(/^ +| +$/, "", rmargin)
    imargin=$6; gsub(/^ +| +$/, "", imargin)
    if (name == "" || name == "Contract") next

    # Strip optional source suffix, e.g. "Math (lib/.../Math.sol)".
    sub(/ \(.*/, "", name)

    if (name in keep) {
        printf("%-42s %16s %18s %18s %18s\n", name, runtime, initcode, rmargin, imargin)
        found=1
        margin_num = rmargin
        gsub(/,/, "", margin_num)
        if (margin_num ~ /^-/) over=1
    }
}
END {
    if (!found) print "No project contracts found in size table."
    if (over) exit 42
}
' "$tmp_output"
table_status=$?
set -e

if [ "$table_status" -eq 42 ]; then
    echo
    echo "Project contracts exceed EIP-170 runtime size limit."
    exit 1
fi

if [ "$table_status" -ne 0 ]; then
    echo
    echo "Failed to parse size table."
    exit "$table_status"
fi

if [ "$status" -ne 0 ]; then
    echo
    echo "forge exited with status $status"
    search_pattern '^Error:' "$tmp_output"
    exit "$status"
fi

#!/usr/bin/env bash

set -euo pipefail

format="both"
out_dir=""
prefix="cobuild-protocol-audit"
include_tests=0
include_docs=1

usage() {
  cat <<'EOF'
Usage: scripts/package-audit-context.sh [options]

Packages audit-relevant protocol files into upload-friendly artifacts.

Options:
  --zip              Create only a .zip archive
  --txt              Create only a merged .txt file
  --both             Create both .zip and .txt (default)
  --out-dir <dir>    Output directory (default: <repo>/audit-packages)
  --name <prefix>    Output filename prefix (default: cobuild-protocol-audit)
  --with-tests       Include test/**/*.sol (excluded by default)
  --no-tests         Exclude test/**/*.sol
  --no-docs          Exclude agent-docs/**/*.md
  -h, --help         Show this help message
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --zip)
      format="zip"
      shift
      ;;
    --txt)
      format="txt"
      shift
      ;;
    --both)
      format="both"
      shift
      ;;
    --out-dir)
      if [ "$#" -lt 2 ]; then
        echo "Error: --out-dir requires a value." >&2
        exit 1
      fi
      out_dir="$2"
      shift 2
      ;;
    --name)
      if [ "$#" -lt 2 ]; then
        echo "Error: --name requires a value." >&2
        exit 1
      fi
      prefix="$2"
      shift 2
      ;;
    --with-tests)
      include_tests=1
      shift
      ;;
    --no-tests)
      include_tests=0
      shift
      ;;
    --no-docs)
      include_docs=0
      shift
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
done

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

if [ -z "$out_dir" ]; then
  out_dir="$ROOT/audit-packages"
fi

mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

if [ "$format" = "zip" ] || [ "$format" = "both" ]; then
  if ! command -v zip >/dev/null 2>&1; then
    echo "Error: zip is required for --zip/--both modes." >&2
    exit 1
  fi
fi

timestamp="$(date -u '+%Y%m%d-%H%M%SZ')"
base_name="${prefix}-${timestamp}"

manifest="$(mktemp)"
missing_imports="$(mktemp)"
cleanup() {
  rm -f "$manifest" "$missing_imports"
}
trap cleanup EXIT

list_tree_files() {
  local rel_dir="$1"
  local file_glob="$2"

  if [ ! -d "$ROOT/$rel_dir" ]; then
    return 0
  fi

  find "$ROOT/$rel_dir" -type f -name "$file_glob" -print | sed "s#^$ROOT/##"
}

is_excluded_audit_path() {
  case "$1" in
    *CobuildSwap*|*cobuildswap*)
      return 0
      ;;
    src/interfaces/ICobuildSwap.sol|src/interfaces/external/uniswap/IUniversalRouter.sol|src/interfaces/external/uniswap/permit2/IAllowanceTransfer.sol)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

{
  for relpath in AGENTS.md ARCHITECTURE.md README.md foundry.toml remappings.txt package.json; do
    if [ -f "$ROOT/$relpath" ]; then
      echo "$relpath"
    fi
  done

  list_tree_files src '*.sol'

  if [ "$include_tests" -eq 1 ]; then
    list_tree_files test '*.sol'
  fi

  if [ "$include_docs" -eq 1 ]; then
    list_tree_files agent-docs '*.md'
  fi
} | awk 'NF' | sort -u | while IFS= read -r relpath; do
  if is_excluded_audit_path "$relpath"; then
    continue
  fi

  if [ -f "$ROOT/$relpath" ]; then
    echo "$relpath"
  else
    echo "Warning: skipping missing selected file: $relpath" >&2
  fi
done >"$manifest"

file_count="$(wc -l < "$manifest" | tr -d ' ')"
if [ "$file_count" = "0" ]; then
  echo "Error: no files matched packaging filters." >&2
  exit 1
fi

resolve_import_path() {
  local from_file="$1"
  local import_path="$2"
  local combined

  if [[ "$import_path" == src/* ]]; then
    combined="$import_path"
  else
    local base_dir="."
    if [[ "$from_file" == */* ]]; then
      base_dir="${from_file%/*}"
    fi
    combined="$base_dir/$import_path"
  fi

  local IFS='/'
  local -a parts out_parts
  read -r -a parts <<< "$combined"

  for part in "${parts[@]}"; do
    case "$part" in
      ""|".")
        continue
        ;;
      "..")
        if [ "${#out_parts[@]}" -eq 0 ]; then
          return 1
        fi
        unset "out_parts[${#out_parts[@]}-1]"
        ;;
      *)
        out_parts+=("$part")
        ;;
    esac
  done

  if [ "${#out_parts[@]}" -eq 0 ]; then
    return 1
  fi

  (IFS='/'; printf '%s\n' "${out_parts[*]}")
}

validate_solidity_import_closure() {
  local has_errors=0

  extract_solidity_imports() {
    local relpath="$1"
    perl -0777 -ne 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g; while (/\bimport\s+(?:[^"\x27;]+?\s+from\s+)?["\x27]([^"\x27]+)["\x27]\s*;/g) { print "$1\n"; }' \
      "$ROOT/$relpath"
  }

  while IFS= read -r relpath; do
    case "$relpath" in
      *.sol) ;;
      *) continue ;;
    esac

    while IFS= read -r import_path; do
      case "$import_path" in
        ./*|../*|src/*) ;;
        *) continue ;;
      esac

      local resolved_path
      if ! resolved_path="$(resolve_import_path "$relpath" "$import_path")"; then
        printf '%s -> %s (resolved outside repo)\n' "$relpath" "$import_path" >>"$missing_imports"
        has_errors=1
        continue
      fi

      if [ ! -f "$ROOT/$resolved_path" ]; then
        printf '%s -> %s (file not found: %s)\n' "$relpath" "$import_path" "$resolved_path" >>"$missing_imports"
        has_errors=1
        continue
      fi

      if ! grep -Fxq "$resolved_path" "$manifest"; then
        printf '%s -> %s (not packaged: %s)\n' "$relpath" "$import_path" "$resolved_path" >>"$missing_imports"
        has_errors=1
      fi
    done < <(extract_solidity_imports "$relpath")
  done <"$manifest"

  if [ "$has_errors" -ne 0 ]; then
    echo "Error: package manifest failed Solidity import closure check." >&2
    sort -u "$missing_imports" >&2
    exit 1
  fi
}

validate_solidity_import_closure

zip_path=""
txt_path=""

if [ "$format" = "zip" ] || [ "$format" = "both" ]; then
  zip_path="$out_dir/$base_name.zip"
  (
    cd "$ROOT"
    zip -q "$zip_path" -@ <"$manifest"
  )
fi

if [ "$format" = "txt" ] || [ "$format" = "both" ]; then
  txt_path="$out_dir/$base_name.txt"
  {
    echo "# Cobuild Protocol Audit Bundle"
    echo "# Generated (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# Repository: $ROOT"
    echo "# Files: $file_count"

    while IFS= read -r relpath; do
      printf '\n===== FILE: %s =====\n' "$relpath"
      cat -- "$ROOT/$relpath"
      printf '\n'
    done <"$manifest"
  } >"$txt_path"
fi

echo "Audit package created."
echo "Included files: $file_count"

if [ -n "$zip_path" ]; then
  echo "ZIP: $zip_path ($(du -h "$zip_path" | awk '{print $1}'))"
fi

if [ -n "$txt_path" ]; then
  echo "TXT: $txt_path ($(du -h "$txt_path" | awk '{print $1}'))"
fi

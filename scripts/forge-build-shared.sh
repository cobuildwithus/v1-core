#!/usr/bin/env bash

set -euo pipefail

wait_for_lock=true
poll_seconds="${SHARED_BUILD_POLL_SECONDS:-3}"
threads="${SHARED_BUILD_THREADS:-0}"
stale_lock_seconds="${SHARED_BUILD_STALE_LOCK_SECONDS:-120}"
dynamic_test_linking="${SHARED_BUILD_DYNAMIC_TEST_LINKING:-0}"
sparse_mode="${SHARED_BUILD_SPARSE_MODE:-0}"
build_namespace="${SHARED_BUILD_NAMESPACE:-default}"
build_args=()
lock_acquired=false

fingerprint_scope_paths=(
  "src"
  "test"
  "scripts"
  "foundry.toml"
  "remappings.txt"
  "package.json"
  "pnpm-lock.yaml"
  ".gitmodules"
  "lib"
)

usage() {
  cat <<'EOF' >&2
Usage: scripts/forge-build-shared.sh [options] [-- forge-build-args...]

Runs `forge build -q` in a single queued lane for the current repository.
If the workspace fingerprint already has a successful shared build, the build
is skipped and existing artifacts are reused.

Options:
  --no-wait          Exit if another shared build is active.
  --poll-seconds N   Poll interval while waiting for build lock (default: 3).
  --threads N        Pass -j N to forge build (default: SHARED_BUILD_THREADS or 0=all cores).
  -h, --help         Show this help.

Environment:
  SHARED_BUILD_STALE_LOCK_SECONDS=<n>   Remove ownerless lock dirs older than n seconds (default: 120).
  SHARED_BUILD_DYNAMIC_TEST_LINKING=1   Pass --dynamic-test-linking to forge build.
  SHARED_BUILD_SPARSE_MODE=1            Run forge build with FOUNDRY_SPARSE_MODE=true.
  SHARED_BUILD_NAMESPACE=<name>         Use per-namespace lock/success files (default: default).
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-wait)
      wait_for_lock=false
      shift
      ;;
    --poll-seconds)
      [ "$#" -ge 2 ] || usage
      poll_seconds="$2"
      shift 2
      ;;
    --threads)
      [ "$#" -ge 2 ] || usage
      threads="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      build_args+=("$@")
      break
      ;;
    *)
      build_args+=("$1")
      shift
      ;;
  esac
done

if ! [[ "$poll_seconds" =~ ^[0-9]+$ ]] || [ "$poll_seconds" -lt 1 ]; then
  printf 'Error: --poll-seconds must be a positive integer\n' >&2
  exit 1
fi

if [ -n "$threads" ] && { ! [[ "$threads" =~ ^[0-9]+$ ]] || [ "$threads" -lt 0 ]; }; then
  printf 'Error: --threads must be a non-negative integer\n' >&2
  exit 1
fi

if ! [[ "$stale_lock_seconds" =~ ^[0-9]+$ ]] || [ "$stale_lock_seconds" -lt 1 ]; then
  printf 'Error: SHARED_BUILD_STALE_LOCK_SECONDS must be a positive integer\n' >&2
  exit 1
fi

if ! [[ "$build_namespace" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'Error: SHARED_BUILD_NAMESPACE must match ^[A-Za-z0-9._-]+$\n' >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Error: not inside a git repository\n' >&2
  exit 1
fi

git_dir="$(git rev-parse --git-dir)"
runtime_dir="$git_dir/agent-runtime"
if [ "$build_namespace" = "default" ]; then
  lock_dir="$runtime_dir/forge-build.lock"
  success_file="$runtime_dir/forge-build.last-success"
else
  lock_dir="$runtime_dir/forge-build.${build_namespace}.lock"
  success_file="$runtime_dir/forge-build.${build_namespace}.last-success"
fi

mkdir -p "$runtime_dir"

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

workspace_fingerprint() {
  local untracked_file

  {
    git rev-parse HEAD 2>/dev/null || printf 'NO_HEAD\n'
    printf 'FOUNDRY_PROFILE=%s\n' "${FOUNDRY_PROFILE:-default}"
    printf 'FOUNDRY_OUT=%s\n' "${FOUNDRY_OUT:-out}"
    printf 'FOUNDRY_CACHE_PATH=%s\n' "${FOUNDRY_CACHE_PATH:-cache}"
    printf 'SHARED_BUILD_DYNAMIC_TEST_LINKING=%s\n' "$dynamic_test_linking"
    printf 'SHARED_BUILD_SPARSE_MODE=%s\n' "$sparse_mode"
    git diff -- "${fingerprint_scope_paths[@]}"
    git diff --cached -- "${fingerprint_scope_paths[@]}"

    while IFS= read -r untracked_file; do
      [ -f "$untracked_file" ] || continue
      printf 'UNTRACKED %s\n' "$untracked_file"
      shasum -a 256 "$untracked_file"
    done < <(git ls-files -o --exclude-standard -- "${fingerprint_scope_paths[@]}" | LC_ALL=C sort)
  } | shasum -a 256 | awk '{print $1}'
}

read_owner_pid() {
  local owner_file="$1"
  [ -f "$owner_file" ] || return 1
  awk -F= '/^pid=/{print $2; exit}' "$owner_file"
}

lock_age_seconds() {
  local path="$1"
  local now
  local modified
  now="$(date +%s)"
  modified="$(stat -f '%m' "$path" 2>/dev/null || printf '0')"
  if ! [[ "$modified" =~ ^[0-9]+$ ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "$((now - modified))"
}

release_lock() {
  if [ "$lock_acquired" = true ] && [ -d "$lock_dir" ]; then
    rm -rf "$lock_dir"
  fi
}
trap release_lock EXIT INT TERM

acquire_lock() {
  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      return 0
    fi

    local owner_file="$lock_dir/owner"
    local owner_pid
    local age

    owner_pid="$(read_owner_pid "$owner_file" || true)"

    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      printf '[%s] Removing stale forge-build lock (dead pid %s)\n' "$(utc_now)" "$owner_pid" >&2
      rm -rf "$lock_dir"
      continue
    fi

    if [ -z "$owner_pid" ] && [ -d "$lock_dir" ]; then
      age="$(lock_age_seconds "$lock_dir")"
      if [ "$age" -gt "$stale_lock_seconds" ]; then
        printf '[%s] Removing stale forge-build lock (age=%ss, no owner pid)\n' "$(utc_now)" "$age" >&2
        rm -rf "$lock_dir"
        continue
      fi
    fi

    if [ "$wait_for_lock" = false ]; then
      printf '[%s] Shared forge build already running' "$(utc_now)" >&2
      if [ -n "$owner_pid" ]; then
        printf ' (pid=%s)' "$owner_pid" >&2
      fi
      printf '\n' >&2
      return 1
    fi

    printf '[%s] Waiting for shared forge-build lane' "$(utc_now)"
    if [ -n "$owner_pid" ]; then
      printf ' (owner pid=%s)' "$owner_pid"
    fi
    printf '\n'
    sleep "$poll_seconds"
  done
}

read_success_fingerprint() {
  [ -f "$success_file" ] || return 1
  awk -F= '/^fingerprint=/{print $2; exit}' "$success_file"
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

has_build_outputs() {
  local out_dir="${FOUNDRY_OUT:-out}"
  local cache_dir="${FOUNDRY_CACHE_PATH:-cache}"
  [ -d "$out_dir" ] && [ -f "$cache_dir/solidity-files-cache.json" ]
}

if ! acquire_lock; then
  exit 1
fi
lock_acquired=true

{
  printf 'pid=%s\n' "$$"
  printf 'started=%s\n' "$(utc_now)"
  printf 'cwd=%s\n' "$(pwd)"
  printf 'namespace=%s\n' "$build_namespace"
} > "$lock_dir/owner"

current_fingerprint="$(workspace_fingerprint)"
previous_fingerprint="$(read_success_fingerprint || true)"

if [ -n "$previous_fingerprint" ] && [ "$previous_fingerprint" = "$current_fingerprint" ] && has_build_outputs; then
  printf '[%s] Reusing shared forge build for fingerprint %s\n' "$(utc_now)" "$current_fingerprint"
  exit 0
fi

build_cmd=(forge build -q)
if [ -n "$threads" ]; then
  build_cmd+=(-j "$threads")
fi
if is_truthy "$dynamic_test_linking"; then
  build_cmd+=(--dynamic-test-linking)
fi
if [ "${#build_args[@]}" -gt 0 ]; then
  build_cmd+=("${build_args[@]}")
fi

printf '[%s] Running shared forge build: %s\n' "$(utc_now)" "${build_cmd[*]}"
if is_truthy "$sparse_mode"; then
  FOUNDRY_SPARSE_MODE=true "${build_cmd[@]}"
else
  "${build_cmd[@]}"
fi

success_tmp="$(mktemp "$runtime_dir/forge-build.success.XXXXXX")"
{
  printf 'fingerprint=%s\n' "$current_fingerprint"
  printf 'built_at=%s\n' "$(utc_now)"
  printf 'pid=%s\n' "$$"
  printf 'cwd=%s\n' "$(pwd)"
} > "$success_tmp"
mv "$success_tmp" "$success_file"

printf '[%s] Shared forge build completed\n' "$(utc_now)"

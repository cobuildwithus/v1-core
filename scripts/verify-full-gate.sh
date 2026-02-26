#!/usr/bin/env bash

set -euo pipefail

wait_for_lock=true
allow_stale=true
fail_on_stale=false
poll_seconds=5

usage() {
  cat <<'EOF' >&2
Usage: scripts/verify-full-gate.sh [options]

Runs the full local verification gate in a single queued lane:
  1) scripts/forge-build-shared.sh
  2) pnpm -s test:lite:shared

Options:
  --no-wait          Exit if another full-gate run is active.
  --allow-stale      Preserve run result even if workspace changes during the run (default).
  --fail-on-stale    Exit 86 when workspace changes during the run.
  --poll-seconds N   Poll interval while waiting for queue lock (default: 5).
  -h, --help         Show this help.
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-wait)
      wait_for_lock=false
      shift
      ;;
    --allow-stale)
      allow_stale=true
      fail_on_stale=false
      shift
      ;;
    --fail-on-stale)
      fail_on_stale=true
      allow_stale=false
      shift
      ;;
    --poll-seconds)
      [ "$#" -ge 2 ] || usage
      poll_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'Error: unknown option: %s\n' "$1" >&2
      usage
      ;;
  esac
done

if ! [[ "$poll_seconds" =~ ^[0-9]+$ ]] || [ "$poll_seconds" -lt 1 ]; then
  printf 'Error: --poll-seconds must be a positive integer\n' >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Error: not inside a git repository\n' >&2
  exit 1
fi

git_dir="$(git rev-parse --git-dir)"
runtime_dir="$git_dir/agent-runtime"
lock_dir="$runtime_dir/full-gate.lock"
logs_dir="$runtime_dir/full-gate-logs"
active_log_file="$runtime_dir/full-gate.active-log"
latest_log_file="$runtime_dir/full-gate.latest-log"

mkdir -p "$runtime_dir" "$logs_dir"

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

workspace_fingerprint() {
  {
    git rev-parse HEAD 2>/dev/null || printf 'NO_HEAD\n'
    git status --porcelain=v2 --untracked-files=all
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

acquire_lock() {
  while true; do
    if mkdir "$lock_dir" 2>/dev/null; then
      return 0
    fi

    owner_file="$lock_dir/owner"
    owner_pid="$(read_owner_pid "$owner_file" || true)"
    active_log="$(cat "$active_log_file" 2>/dev/null || true)"

    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      printf '[%s] Removing stale full-gate lock (dead pid %s)\n' "$(utc_now)" "$owner_pid" >&2
      rm -rf "$lock_dir"
      continue
    fi

    if [ -z "$owner_pid" ] && [ -d "$lock_dir" ]; then
      age="$(lock_age_seconds "$lock_dir")"
      if [ "$age" -gt 600 ]; then
        printf '[%s] Removing stale full-gate lock (age=%ss, no owner pid)\n' "$(utc_now)" "$age" >&2
        rm -rf "$lock_dir"
        continue
      fi
    fi

    if [ "$wait_for_lock" = false ]; then
      printf '[%s] Full gate already running' "$(utc_now)" >&2
      if [ -n "$owner_pid" ]; then
        printf ' (pid=%s)' "$owner_pid" >&2
      fi
      if [ -n "$active_log" ]; then
        printf '. Active log: %s' "$active_log" >&2
      fi
      printf '\n' >&2
      return 1
    fi

    printf '[%s] Waiting for full-gate queue' "$(utc_now)"
    if [ -n "$owner_pid" ]; then
      printf ' (owner pid=%s)' "$owner_pid"
    fi
    if [ -n "$active_log" ]; then
      printf '. Active log: %s' "$active_log"
    fi
    printf '\n'
    sleep "$poll_seconds"
  done
}

if ! acquire_lock; then
  exit 1
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-pid$$"
log_file="$logs_dir/full-gate-$run_id.log"
touch "$log_file"

cleanup() {
  # Keep the last completed run pointer for observers.
  printf '%s\n' "$log_file" > "$latest_log_file"

  if [ -f "$active_log_file" ]; then
    current_active="$(cat "$active_log_file" 2>/dev/null || true)"
    if [ "$current_active" = "$log_file" ]; then
      rm -f "$active_log_file"
    fi
  fi

  rm -rf "$lock_dir"
}
trap cleanup EXIT INT TERM

{
  printf 'pid=%s\n' "$$"
  printf 'started=%s\n' "$(utc_now)"
  printf 'cwd=%s\n' "$(pwd)"
  printf 'log=%s\n' "$log_file"
} > "$lock_dir/owner"
printf '%s\n' "$log_file" > "$active_log_file"

log() {
  printf '[%s] %s\n' "$(utc_now)" "$*" | tee -a "$log_file"
}

run_step() {
  local name="$1"
  shift
  log "START $name: $*"
  if "$@" 2>&1 | tee -a "$log_file"; then
    log "OK $name"
    return 0
  fi
  local code=$?
  log "FAIL $name (exit=$code)"
  return "$code"
}

fingerprint_before="$(workspace_fingerprint)"
log "Queued full gate started. Log file: $log_file"
log "Workspace fingerprint (before): $fingerprint_before"

run_exit=0
build_cmd=(scripts/forge-build-shared.sh)
full_gate_build_threads="${FULL_GATE_BUILD_THREADS:-${SHARED_BUILD_THREADS:-0}}"
if [ -n "$full_gate_build_threads" ]; then
  build_cmd+=(--threads "$full_gate_build_threads")
fi

if ! run_step "build" "${build_cmd[@]}"; then
  run_exit=$?
else
  if ! run_step "test:lite:shared" pnpm -s test:lite:shared; then
    run_exit=$?
  fi
fi

fingerprint_after="$(workspace_fingerprint)"
log "Workspace fingerprint (after): $fingerprint_after"

final_exit="$run_exit"
if [ "$fingerprint_before" != "$fingerprint_after" ]; then
  if [ "$fail_on_stale" = true ]; then
    log "STALE workspace detected: marking run invalid due to --fail-on-stale."
    final_exit=86
  else
    log "STALE workspace detected: returning result for the snapshot active at run start."
  fi
fi

if [ "$final_exit" -eq 0 ]; then
  log "FULL GATE PASSED"
else
  log "FULL GATE FAILED (exit=$final_exit)"
fi

exit "$final_exit"

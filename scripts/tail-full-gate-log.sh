#!/usr/bin/env bash

set -euo pipefail

mode="active"

usage() {
  cat <<'EOF' >&2
Usage: scripts/tail-full-gate-log.sh [--active|--latest]

Options:
  --active  Tail currently running full-gate log (default).
  --latest  Tail the most recent completed/running full-gate log.
  -h, --help
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --active)
      mode="active"
      shift
      ;;
    --latest)
      mode="latest"
      shift
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

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Error: not inside a git repository\n' >&2
  exit 1
fi

git_dir="$(git rev-parse --git-dir)"
runtime_dir="$git_dir/agent-runtime"
active_file="$runtime_dir/full-gate.active-log"
latest_file="$runtime_dir/full-gate.latest-log"

log_file=''
if [ "$mode" = "active" ]; then
  log_file="$(cat "$active_file" 2>/dev/null || true)"
  if [ -z "$log_file" ]; then
    log_file="$(cat "$latest_file" 2>/dev/null || true)"
  fi
else
  log_file="$(cat "$latest_file" 2>/dev/null || true)"
fi

if [ -z "$log_file" ]; then
  printf 'No full-gate log found yet.\n' >&2
  exit 1
fi

if [ ! -f "$log_file" ]; then
  printf 'Recorded log file does not exist: %s\n' "$log_file" >&2
  exit 1
fi

printf 'Tailing full-gate log: %s\n' "$log_file"
exec tail -f "$log_file"

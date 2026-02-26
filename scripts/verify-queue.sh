#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/verify-queue.sh submit [required|full] [--wait] [--timeout-seconds N]
  scripts/verify-queue.sh worker [--no-wait] [--batch-window-seconds N] [--max-batch N] [--worker-lanes N]
  scripts/verify-queue.sh wait <request-id> [--timeout-seconds N]
  scripts/verify-queue.sh status

Commands:
  submit  Enqueue a verification request. Default mode is "required".
          Mode "required" runs: pnpm -s build && pnpm -s test:lite:shared
          Mode "full" runs:     pnpm -s verify:full
  worker  Process queued requests in batches. Requests are grouped by workspace fingerprint.
          Multiple workers can run in parallel across different fingerprints.
  wait    Wait for a specific request result and return its recorded exit code.
  status  Print queue/worker status.

Environment:
  VERIFY_QUEUE_POLL_SECONDS=<n>         Poll interval for wait loops (default: 3).
  VERIFY_QUEUE_BATCH_WINDOW_SECONDS=<n> Worker batch window before execution (default: 5).
  VERIFY_QUEUE_MAX_BATCH=<n>            Max requests processed per batch (default: 50).
  VERIFY_QUEUE_WORKER_LANES=<n>         Max concurrent worker lanes (default: 4).
  VERIFY_QUEUE_LOCK_STALE_SECONDS=<n>   Stale worker-lock cleanup threshold (default: 600).
  VERIFY_QUEUE_RUNTIME_DIR=<path>       Override runtime root (default: <git-dir>/agent-runtime).
USAGE
  exit 2
}

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'Error: not inside a git repository\n' >&2
  exit 1
fi

git_dir="$(git rev-parse --git-dir)"
runtime_dir="${VERIFY_QUEUE_RUNTIME_DIR:-$git_dir/agent-runtime}"
queue_file="$runtime_dir/verify-queue.jsonl"
results_dir="$runtime_dir/verify-queue-results"
logs_dir="$runtime_dir/verify-queue-logs"
ledger_file="$runtime_dir/verify-ledger.md"
append_lock_dir="$runtime_dir/verify-queue.append.lock"
worker_lanes_dir="$runtime_dir/verify-queue.worker-lanes"
fingerprint_locks_dir="$runtime_dir/verify-queue.fingerprint-locks"
lanes_runtime_dir="$runtime_dir/verify-queue-lanes"

mkdir -p "$runtime_dir" "$results_dir" "$logs_dir" "$worker_lanes_dir" "$fingerprint_locks_dir" "$lanes_runtime_dir"
touch "$queue_file"

poll_seconds="${VERIFY_QUEUE_POLL_SECONDS:-3}"
batch_window_seconds="${VERIFY_QUEUE_BATCH_WINDOW_SECONDS:-5}"
max_batch="${VERIFY_QUEUE_MAX_BATCH:-50}"
worker_lanes="${VERIFY_QUEUE_WORKER_LANES:-4}"
lock_stale_seconds="${VERIFY_QUEUE_LOCK_STALE_SECONDS:-600}"

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

active_fingerprint_lock_dir=""
worker_lane_id=""
worker_lane_lock_dir=""
worker_lane_active_file=""

utc_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

workspace_fingerprint() {
  local untracked_file

  {
    git rev-parse HEAD 2>/dev/null || printf 'NO_HEAD\n'
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

write_lock_owner() {
  local dir="$1"
  {
    printf 'pid=%s\n' "$$"
    printf 'started=%s\n' "$(utc_now)"
    printf 'cwd=%s\n' "$(pwd)"
  } > "$dir/owner"
}

require_positive_int() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    printf 'Error: %s must be a positive integer\n' "$name" >&2
    exit 1
  fi
}

acquire_lock() {
  local dir="$1"
  local label="$2"
  local wait_for_lock="$3"
  local poll="$4"
  local stale="$5"

  while true; do
    if mkdir "$dir" 2>/dev/null; then
      return 0
    fi

    local owner_file="$dir/owner"
    local owner_pid
    local age

    owner_pid="$(read_owner_pid "$owner_file" || true)"

    if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" >/dev/null 2>&1; then
      printf '[%s] Removing stale %s lock (dead pid %s)\n' "$(utc_now)" "$label" "$owner_pid" >&2
      rm -rf "$dir"
      continue
    fi

    if [ -z "$owner_pid" ] && [ -d "$dir" ]; then
      age="$(lock_age_seconds "$dir")"
      if [ "$age" -gt "$stale" ]; then
        printf '[%s] Removing stale %s lock (age=%ss, no owner pid)\n' "$(utc_now)" "$label" "$age" >&2
        rm -rf "$dir"
        continue
      fi
    fi

    if [ "$wait_for_lock" = false ]; then
      return 1
    fi

    printf '[%s] Waiting for %s lock' "$(utc_now)" "$label" >&2
    if [ -n "$owner_pid" ]; then
      printf ' (owner pid=%s)' "$owner_pid" >&2
    fi
    printf '\n' >&2
    sleep "$poll"
  done
}

request_has_result() {
  local request_id="$1"
  [ -f "$results_dir/$request_id.json" ]
}

find_coalesced_request_id_locked() {
  local requested_mode="$1"
  local fingerprint="$2"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue

    local id
    local mode
    local fp

    id="$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null || true)"
    mode="$(printf '%s\n' "$line" | jq -r '.mode // "required"' 2>/dev/null || true)"
    fp="$(printf '%s\n' "$line" | jq -r '.fingerprint // "unknown"' 2>/dev/null || true)"

    [ -n "$id" ] || continue
    [ "$fp" = "$fingerprint" ] || continue
    request_has_result "$id" && continue

    case "$requested_mode" in
      required)
        if [ "$mode" = "required" ] || [ "$mode" = "full" ]; then
          printf '%s\n' "$id"
          return 0
        fi
        ;;
      full)
        if [ "$mode" = "full" ]; then
          printf '%s\n' "$id"
          return 0
        fi
        ;;
    esac
  done < <(jq -c '.' "$queue_file" 2>/dev/null || true)

  return 1
}

enqueue_or_coalesce_request() {
  local request_json="$1"
  local requested_mode="$2"
  local fingerprint="$3"
  local compact_line
  local queued_id
  local existing_id

  compact_line="$(printf '%s\n' "$request_json" | jq -c '.')"
  queued_id="$(printf '%s\n' "$request_json" | jq -r '.id')"

  if ! acquire_lock "$append_lock_dir" "verify-queue-append" true 1 120; then
    printf 'Error: failed to acquire append lock\n' >&2
    exit 1
  fi
  write_lock_owner "$append_lock_dir"

  existing_id="$(find_coalesced_request_id_locked "$requested_mode" "$fingerprint" || true)"
  if [ -n "$existing_id" ]; then
    rm -rf "$append_lock_dir"
    printf 'coalesced:%s\n' "$existing_id"
    return 0
  fi

  printf '%s\n' "$compact_line" >> "$queue_file"
  rm -rf "$append_lock_dir"
  printf 'queued:%s\n' "$queued_id"
}

collect_unresolved_requests() {
  local output_file="$1"
  : > "$output_file"

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue

    local id
    id="$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null || true)"
    [ -n "$id" ] || continue

    if ! request_has_result "$id"; then
      printf '%s\n' "$line" >> "$output_file"
    fi
  done < <(jq -c '.' "$queue_file" 2>/dev/null || true)
}

release_fingerprint_lock() {
  if [ -n "$active_fingerprint_lock_dir" ] && [ -d "$active_fingerprint_lock_dir" ]; then
    rm -rf "$active_fingerprint_lock_dir"
  fi
  active_fingerprint_lock_dir=""
}

release_worker_lane_lock() {
  if [ -n "$worker_lane_lock_dir" ] && [ -d "$worker_lane_lock_dir" ]; then
    rm -rf "$worker_lane_lock_dir"
  fi
  worker_lane_lock_dir=""
}

cleanup_worker_runtime() {
  release_fingerprint_lock
  release_worker_lane_lock
  if [ -n "$worker_lane_active_file" ]; then
    rm -f "$worker_lane_active_file"
    worker_lane_active_file=""
  fi
}

collect_pending_batch() {
  local output_file="$1"
  local max_batch_local="$2"
  local unresolved_file
  local fingerprint_order_file
  local selected_fingerprint=""
  local count

  : > "$output_file"
  unresolved_file="$(mktemp "$runtime_dir/verify-queue.unresolved.XXXXXX")"
  fingerprint_order_file="$(mktemp "$runtime_dir/verify-queue.fingerprints.XXXXXX")"

  collect_unresolved_requests "$unresolved_file"
  if [ ! -s "$unresolved_file" ]; then
    rm -f "$unresolved_file" "$fingerprint_order_file"
    return 0
  fi

  jq -r '.fingerprint // "unknown"' "$unresolved_file" | awk '!seen[$0]++' > "$fingerprint_order_file"

  while IFS= read -r fingerprint_candidate || [ -n "$fingerprint_candidate" ]; do
    [ -n "$fingerprint_candidate" ] || continue

    local fp_lock_dir="$fingerprint_locks_dir/$fingerprint_candidate.lock"
    if acquire_lock "$fp_lock_dir" "verify-queue-fingerprint-$fingerprint_candidate" false 1 "$lock_stale_seconds"; then
      write_lock_owner "$fp_lock_dir"
      active_fingerprint_lock_dir="$fp_lock_dir"
      selected_fingerprint="$fingerprint_candidate"
      break
    fi
  done < "$fingerprint_order_file"

  rm -f "$fingerprint_order_file"

  if [ -z "$selected_fingerprint" ]; then
    rm -f "$unresolved_file"
    return 2
  fi

  count=0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue

    local fingerprint
    fingerprint="$(printf '%s\n' "$line" | jq -r '.fingerprint // "unknown"' 2>/dev/null || true)"
    if [ "$fingerprint" = "$selected_fingerprint" ]; then
      printf '%s\n' "$line" >> "$output_file"
      count=$((count + 1))
      if [ "$max_batch_local" -gt 0 ] && [ "$count" -ge "$max_batch_local" ]; then
        break
      fi
    fi
  done < "$unresolved_file"

  rm -f "$unresolved_file"
}

append_ledger_entry() {
  local run_id="$1"
  local started="$2"
  local finished="$3"
  local lane_id="$4"
  local mode="$5"
  local fingerprint="$6"
  local request_ids="$7"
  local exit_code="$8"
  local log_file="$9"

  if [ ! -f "$ledger_file" ]; then
    cat > "$ledger_file" <<'LEDGER'
# Verification Queue Ledger

LEDGER
  fi

  {
    printf '## %s (%s)\n' "$run_id" "$started"
    printf -- '- lane: `%s`\n' "$lane_id"
    printf -- '- mode: `%s`\n' "$mode"
    printf -- '- fingerprint: `%s`\n' "$fingerprint"
    printf -- '- request_ids: `%s`\n' "$request_ids"
    printf -- '- exit_code: `%s`\n' "$exit_code"
    printf -- '- started: `%s`\n' "$started"
    printf -- '- finished: `%s`\n' "$finished"
    printf -- '- log: `%s`\n\n' "$log_file"
  } >> "$ledger_file"
}

record_batch_results() {
  local batch_file="$1"
  local lane_id="$2"
  local mode="$3"
  local fingerprint="$4"
  local started="$5"
  local finished="$6"
  local exit_code="$7"
  local log_file="$8"
  local status

  status="failed"
  if [ "$exit_code" -eq 0 ]; then
    status="passed"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue

    local id
    local requested_mode
    local tmp_file

    id="$(printf '%s\n' "$line" | jq -r '.id // empty')"
    requested_mode="$(printf '%s\n' "$line" | jq -r '.mode // "required"')"
    [ -n "$id" ] || continue

    if request_has_result "$id"; then
      continue
    fi

    tmp_file="$(mktemp "$results_dir/$id.XXXXXX")"
    jq -n \
      --arg id "$id" \
      --arg status "$status" \
      --arg lane_id "$lane_id" \
      --arg requested_mode "$requested_mode" \
      --arg run_mode "$mode" \
      --arg fingerprint "$fingerprint" \
      --arg started_at "$started" \
      --arg finished_at "$finished" \
      --arg log_file "$log_file" \
      --argjson exit_code "$exit_code" \
      '{
        id: $id,
        status: $status,
        lane_id: $lane_id,
        requested_mode: $requested_mode,
        run_mode: $run_mode,
        fingerprint: $fingerprint,
        started_at: $started_at,
        finished_at: $finished_at,
        log_file: $log_file,
        exit_code: $exit_code
      }' > "$tmp_file"
    mv "$tmp_file" "$results_dir/$id.json"
  done < "$batch_file"
}

wait_for_result() {
  local request_id="$1"
  local timeout_seconds="$2"
  local poll_local="$3"
  local started_epoch
  local result_file

  result_file="$results_dir/$request_id.json"
  started_epoch="$(date +%s)"

  while true; do
    if [ -f "$result_file" ]; then
      local exit_code
      local status
      local mode
      local lane_id
      local log_path

      exit_code="$(jq -r '.exit_code // 1' "$result_file")"
      status="$(jq -r '.status // "unknown"' "$result_file")"
      mode="$(jq -r '.run_mode // "required"' "$result_file")"
      lane_id="$(jq -r '.lane_id // "unknown"' "$result_file")"
      log_path="$(jq -r '.log_file // ""' "$result_file")"

      printf '[%s] Request %s %s (mode=%s, lane=%s, exit=%s)\n' "$(utc_now)" "$request_id" "$status" "$mode" "$lane_id" "$exit_code"
      if [ -n "$log_path" ]; then
        printf 'Log file: %s\n' "$log_path"
      fi

      if ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        exit_code=1
      fi
      return "$exit_code"
    fi

    if [ "$timeout_seconds" -gt 0 ]; then
      local now_epoch
      now_epoch="$(date +%s)"
      if [ $((now_epoch - started_epoch)) -ge "$timeout_seconds" ]; then
        printf 'Error: timed out waiting for request %s\n' "$request_id" >&2
        return 124
      fi
    fi

    sleep "$poll_local"
  done
}

acquire_worker_lane() {
  local wait_for_lock="$1"
  local poll_local="$2"
  local stale_seconds="$3"
  local lanes="$4"

  while true; do
    local lane

    lane=1
    while [ "$lane" -le "$lanes" ]; do
      local lane_dir="$worker_lanes_dir/lane-$lane.lock"

      if acquire_lock "$lane_dir" "verify-queue-worker-lane-$lane" false "$poll_local" "$stale_seconds"; then
        worker_lane_id="$lane"
        worker_lane_lock_dir="$lane_dir"
        write_lock_owner "$worker_lane_lock_dir"
        return 0
      fi

      lane=$((lane + 1))
    done

    if [ "$wait_for_lock" = false ]; then
      return 1
    fi

    printf '[%s] Waiting for free verify-queue worker lane (%s configured)\n' "$(utc_now)" "$lanes"
    sleep "$poll_local"
  done
}

run_worker() {
  local wait_for_lock=true
  local batch_window_local="$batch_window_seconds"
  local max_batch_local="$max_batch"
  local poll_local="$poll_seconds"
  local worker_lanes_local="$worker_lanes"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-wait)
        wait_for_lock=false
        shift
        ;;
      --batch-window-seconds)
        [ "$#" -ge 2 ] || usage
        batch_window_local="$2"
        shift 2
        ;;
      --max-batch)
        [ "$#" -ge 2 ] || usage
        max_batch_local="$2"
        shift 2
        ;;
      --poll-seconds)
        [ "$#" -ge 2 ] || usage
        poll_local="$2"
        shift 2
        ;;
      --worker-lanes)
        [ "$#" -ge 2 ] || usage
        worker_lanes_local="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        printf 'Error: unknown worker option: %s\n' "$1" >&2
        usage
        ;;
    esac
  done

  require_positive_int "VERIFY_QUEUE_BATCH_WINDOW_SECONDS" "$batch_window_local"
  require_positive_int "VERIFY_QUEUE_MAX_BATCH" "$max_batch_local"
  require_positive_int "VERIFY_QUEUE_POLL_SECONDS" "$poll_local"
  require_positive_int "VERIFY_QUEUE_WORKER_LANES" "$worker_lanes_local"
  require_positive_int "VERIFY_QUEUE_LOCK_STALE_SECONDS" "$lock_stale_seconds"

  if ! acquire_worker_lane "$wait_for_lock" "$poll_local" "$lock_stale_seconds" "$worker_lanes_local"; then
    if [ "$wait_for_lock" = false ]; then
      return 0
    fi
    return 1
  fi

  worker_lane_active_file="$runtime_dir/verify-queue.active.lane-$worker_lane_id"
  trap cleanup_worker_runtime EXIT INT TERM

  {
    printf 'pid=%s\n' "$$"
    printf 'lane=%s\n' "$worker_lane_id"
    printf 'started=%s\n' "$(utc_now)"
  } > "$worker_lane_active_file"

  if [ "$batch_window_local" -gt 0 ]; then
    sleep "$batch_window_local"
  fi

  while true; do
    local batch_file
    local batch_status
    local run_id
    local mode
    local fingerprint
    local request_ids
    local started_at
    local finished_at
    local log_file
    local run_exit
    local lane_root
    local lane_out
    local lane_cache
    local lane_env

    batch_file="$(mktemp "$runtime_dir/verify-queue.batch.XXXXXX")"
    batch_status=0
    collect_pending_batch "$batch_file" "$max_batch_local" || batch_status=$?

    if [ "$batch_status" -eq 2 ]; then
      rm -f "$batch_file"
      sleep "$poll_local"
      continue
    fi

    if [ "$batch_status" -ne 0 ]; then
      rm -f "$batch_file"
      return "$batch_status"
    fi

    if [ ! -s "$batch_file" ]; then
      rm -f "$batch_file"
      break
    fi

    run_id="$(date -u +%Y%m%dT%H%M%SZ)-lane$worker_lane_id-pid$$"
    log_file="$logs_dir/verify-queue-$run_id.log"
    touch "$log_file"

    mode="required"
    if jq -s -e 'any(.[]; .mode == "full")' "$batch_file" >/dev/null 2>&1; then
      mode="full"
    fi

    fingerprint="$(head -n 1 "$batch_file" | jq -r '.fingerprint // "unknown"')"
    request_ids="$(jq -r '.id' "$batch_file" | paste -sd ',' -)"
    started_at="$(utc_now)"

    lane_root="$lanes_runtime_dir/lane-$worker_lane_id/$fingerprint"
    lane_out="$lane_root/out"
    lane_cache="$lane_root/cache"
    mkdir -p "$lane_out" "$lane_cache"

    {
      printf '[%s] START batch run_id=%s lane=%s mode=%s fingerprint=%s request_ids=%s\n' \
        "$started_at" "$run_id" "$worker_lane_id" "$mode" "$fingerprint" "$request_ids"
      printf '[%s] lane_paths out=%s cache=%s\n' "$started_at" "$lane_out" "$lane_cache"
    } | tee -a "$log_file"

    run_exit=0
    lane_env=(
      "FOUNDRY_OUT=$lane_out"
      "FOUNDRY_CACHE_PATH=$lane_cache"
      "SHARED_BUILD_NAMESPACE=verifyq-$fingerprint"
    )

    if [ "$mode" = "full" ]; then
      if env "${lane_env[@]}" pnpm -s verify:full 2>&1 | tee -a "$log_file"; then
        run_exit=0
      else
        run_exit=$?
      fi
    else
      if env "${lane_env[@]}" pnpm -s build 2>&1 | tee -a "$log_file"; then
        if env "${lane_env[@]}" pnpm -s test:lite:shared 2>&1 | tee -a "$log_file"; then
          run_exit=0
        else
          run_exit=$?
        fi
      else
        run_exit=$?
      fi
    fi

    finished_at="$(utc_now)"
    {
      printf '[%s] END batch run_id=%s lane=%s exit=%s\n' "$finished_at" "$run_id" "$worker_lane_id" "$run_exit"
    } | tee -a "$log_file"

    record_batch_results "$batch_file" "$worker_lane_id" "$mode" "$fingerprint" "$started_at" "$finished_at" "$run_exit" "$log_file"
    append_ledger_entry "$run_id" "$started_at" "$finished_at" "$worker_lane_id" "$mode" "$fingerprint" "$request_ids" "$run_exit" "$log_file"

    release_fingerprint_lock
    rm -f "$batch_file"
  done
}

submit_request() {
  local mode="required"
  local wait_for_result_flag=false
  local start_worker=true
  local timeout_seconds=0
  local poll_local="$poll_seconds"
  local batch_window_local="$batch_window_seconds"
  local max_batch_local="$max_batch"
  local worker_lanes_local="$worker_lanes"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      required|full)
        mode="$1"
        shift
        ;;
      --mode)
        [ "$#" -ge 2 ] || usage
        mode="$2"
        shift 2
        ;;
      --wait)
        wait_for_result_flag=true
        shift
        ;;
      --no-start-worker)
        start_worker=false
        shift
        ;;
      --timeout-seconds)
        [ "$#" -ge 2 ] || usage
        timeout_seconds="$2"
        shift 2
        ;;
      --poll-seconds)
        [ "$#" -ge 2 ] || usage
        poll_local="$2"
        shift 2
        ;;
      --batch-window-seconds)
        [ "$#" -ge 2 ] || usage
        batch_window_local="$2"
        shift 2
        ;;
      --max-batch)
        [ "$#" -ge 2 ] || usage
        max_batch_local="$2"
        shift 2
        ;;
      --worker-lanes)
        [ "$#" -ge 2 ] || usage
        worker_lanes_local="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        printf 'Error: unknown submit option: %s\n' "$1" >&2
        usage
        ;;
    esac
  done

  case "$mode" in
    required|full) ;;
    *)
      printf 'Error: mode must be "required" or "full"\n' >&2
      exit 1
      ;;
  esac

  require_positive_int "VERIFY_QUEUE_POLL_SECONDS" "$poll_local"
  require_positive_int "VERIFY_QUEUE_BATCH_WINDOW_SECONDS" "$batch_window_local"
  require_positive_int "VERIFY_QUEUE_MAX_BATCH" "$max_batch_local"
  require_positive_int "VERIFY_QUEUE_WORKER_LANES" "$worker_lanes_local"
  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -lt 0 ]; then
    printf 'Error: --timeout-seconds must be a non-negative integer\n' >&2
    exit 1
  fi

  local request_id
  local created_at
  local fingerprint
  local request_json
  local queue_result
  local coalesced=false

  request_id="$(date -u +%Y%m%dT%H%M%SZ)-pid$$-$RANDOM"
  created_at="$(utc_now)"
  fingerprint="$(workspace_fingerprint)"

  request_json="$(jq -cn \
    --arg id "$request_id" \
    --arg created_at "$created_at" \
    --arg mode "$mode" \
    --arg fingerprint "$fingerprint" \
    --arg cwd "$(pwd)" \
    --argjson pid "$$" \
    '{
      id: $id,
      created_at: $created_at,
      mode: $mode,
      fingerprint: $fingerprint,
      cwd: $cwd,
      pid: $pid
    }')"

  queue_result="$(enqueue_or_coalesce_request "$request_json" "$mode" "$fingerprint")"
  case "$queue_result" in
    queued:*)
      request_id="${queue_result#queued:}"
      printf 'Queued request %s (mode=%s, fingerprint=%s)\n' "$request_id" "$mode" "$fingerprint"
      ;;
    coalesced:*)
      request_id="${queue_result#coalesced:}"
      coalesced=true
      printf 'Coalesced request onto %s (mode=%s, fingerprint=%s)\n' "$request_id" "$mode" "$fingerprint"
      ;;
    *)
      printf 'Error: unexpected queue result: %s\n' "$queue_result" >&2
      exit 1
      ;;
  esac

  if [ "$start_worker" = true ]; then
    (
      scripts/verify-queue.sh worker \
        --no-wait \
        --batch-window-seconds "$batch_window_local" \
        --max-batch "$max_batch_local" \
        --poll-seconds "$poll_local" \
        --worker-lanes "$worker_lanes_local" >/dev/null 2>&1 || true
    ) &
  fi

  if [ "$wait_for_result_flag" = true ]; then
    wait_for_result "$request_id" "$timeout_seconds" "$poll_local"
  elif [ "$coalesced" = true ]; then
    printf 'Tip: use scripts/verify-queue.sh wait %s to block for this coalesced request.\n' "$request_id"
  fi
}

wait_command() {
  [ "$#" -ge 1 ] || usage
  local request_id="$1"
  shift
  local timeout_seconds=0
  local poll_local="$poll_seconds"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout-seconds)
        [ "$#" -ge 2 ] || usage
        timeout_seconds="$2"
        shift 2
        ;;
      --poll-seconds)
        [ "$#" -ge 2 ] || usage
        poll_local="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      *)
        printf 'Error: unknown wait option: %s\n' "$1" >&2
        usage
        ;;
    esac
  done

  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [ "$timeout_seconds" -lt 0 ]; then
    printf 'Error: --timeout-seconds must be a non-negative integer\n' >&2
    exit 1
  fi
  require_positive_int "VERIFY_QUEUE_POLL_SECONDS" "$poll_local"

  wait_for_result "$request_id" "$timeout_seconds" "$poll_local"
}

status_command() {
  local total=0
  local pending=0
  local running_lanes=0
  local active_fingerprints=0

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue

    local id
    id="$(printf '%s\n' "$line" | jq -r '.id // empty' 2>/dev/null || true)"
    [ -n "$id" ] || continue

    total=$((total + 1))
    if ! request_has_result "$id"; then
      pending=$((pending + 1))
    fi
  done < <(jq -c '.' "$queue_file" 2>/dev/null || true)

  if [ -d "$worker_lanes_dir" ]; then
    while IFS= read -r lane_lock || [ -n "$lane_lock" ]; do
      [ -d "$lane_lock" ] || continue
      local owner_pid
      owner_pid="$(read_owner_pid "$lane_lock/owner" || true)"
      if [ -n "$owner_pid" ] && kill -0 "$owner_pid" >/dev/null 2>&1; then
        running_lanes=$((running_lanes + 1))
      fi
    done < <(find "$worker_lanes_dir" -maxdepth 1 -type d -name 'lane-*.lock' | sort)
  fi

  if [ -d "$fingerprint_locks_dir" ]; then
    while IFS= read -r fp_lock || [ -n "$fp_lock" ]; do
      [ -d "$fp_lock" ] || continue
      local owner_pid
      owner_pid="$(read_owner_pid "$fp_lock/owner" || true)"
      if [ -n "$owner_pid" ] && kill -0 "$owner_pid" >/dev/null 2>&1; then
        active_fingerprints=$((active_fingerprints + 1))
      fi
    done < <(find "$fingerprint_locks_dir" -maxdepth 1 -type d -name '*.lock' | sort)
  fi

  printf 'verify-queue total=%s pending=%s\n' "$total" "$pending"
  if [ "$running_lanes" -gt 0 ]; then
    printf 'workers=running lanes=%s/%s\n' "$running_lanes" "$worker_lanes"
  else
    printf 'workers=idle lanes=0/%s\n' "$worker_lanes"
  fi
  printf 'active_fingerprint_locks=%s\n' "$active_fingerprints"
  printf 'queue_file=%s\n' "$queue_file"
  printf 'results_dir=%s\n' "$results_dir"
  printf 'ledger_file=%s\n' "$ledger_file"
}

command="${1:-}"
[ -n "$command" ] || usage
shift || true

case "$command" in
  submit)
    submit_request "$@"
    ;;
  worker)
    run_worker "$@"
    ;;
  wait)
    wait_command "$@"
    ;;
  status)
    status_command
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    printf 'Error: unknown command: %s\n' "$command" >&2
    usage
    ;;
esac

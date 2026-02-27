#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: scripts/test-scope.sh <scope> [forge-test-args...]

Scopes:
  tcr        Run TCR + arbitrator-focused tests.
  arbitrator Run arbitrator-focused tests only.
  budget     Run budget-stack focused tests across flow/goal/TCR modules.
  flows      Run flow engine/allocation-focused tests.
  goals      Run treasury/stake/reward-focused tests.
  invariant  Run invariant test suite only.
  all-lite   Run non-invariant full regression suite.

Environment:
  TEST_SCOPE_THREADS=<n>                 Thread cap passed to forge test via -j (default: 0=all cores).
  TEST_SCOPE_BUILD_THREADS=<n>           Shared-build thread cap (default: SHARED_BUILD_THREADS or 0).
  TEST_SCOPE_SKIP_SHARED_BUILD=1         Skip shared prebuild and let forge test compile directly.
  TEST_SCOPE_DYNAMIC_TEST_LINKING=1      Pass --dynamic-test-linking to forge test.
  TEST_SCOPE_SPARSE_MODE=1               Run forge test with FOUNDRY_SPARSE_MODE=true.
  TEST_SCOPE_BUILD_DYNAMIC_TEST_LINKING=1  Force shared build to use --dynamic-test-linking.
  TEST_SCOPE_BUILD_SPARSE_MODE=1         Force shared build to use FOUNDRY_SPARSE_MODE=true.
EOF
  exit 2
}

if [ "$#" -lt 1 ]; then
  usage
fi

scope="$1"
shift

threads="${TEST_SCOPE_THREADS:-0}"
if [ -n "$threads" ] && ! [[ "$threads" =~ ^[0-9]+$ ]]; then
  printf 'Error: TEST_SCOPE_THREADS must be a non-negative integer\n' >&2
  exit 1
fi

build_threads="${TEST_SCOPE_BUILD_THREADS:-${SHARED_BUILD_THREADS:-0}}"
if [ -n "$build_threads" ] && ! [[ "$build_threads" =~ ^[0-9]+$ ]]; then
  printf 'Error: TEST_SCOPE_BUILD_THREADS must be a non-negative integer\n' >&2
  exit 1
fi

skip_shared_build="${TEST_SCOPE_SKIP_SHARED_BUILD:-0}"
dynamic_test_linking="${TEST_SCOPE_DYNAMIC_TEST_LINKING:-0}"
sparse_mode="${TEST_SCOPE_SPARSE_MODE:-0}"
build_dynamic_test_linking="${TEST_SCOPE_BUILD_DYNAMIC_TEST_LINKING:-$dynamic_test_linking}"
build_sparse_mode="${TEST_SCOPE_BUILD_SPARSE_MODE:-$sparse_mode}"

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

if ! is_truthy "$skip_shared_build"; then
  build_cmd=(scripts/forge-build-shared.sh)
  build_env=()
  if [ -n "$build_threads" ]; then
    build_cmd+=(--threads "$build_threads")
  fi
  if is_truthy "$build_dynamic_test_linking"; then
    build_env+=(SHARED_BUILD_DYNAMIC_TEST_LINKING=1)
  fi
  if is_truthy "$build_sparse_mode"; then
    build_env+=(SHARED_BUILD_SPARSE_MODE=1)
  fi
  if [ "${#build_env[@]}" -gt 0 ]; then
    env "${build_env[@]}" "${build_cmd[@]}"
  else
    "${build_cmd[@]}"
  fi
fi

cmd=(forge test -vvv)

if [ -n "$threads" ]; then
  cmd+=(-j "$threads")
fi
if is_truthy "$dynamic_test_linking"; then
  cmd+=(--dynamic-test-linking)
fi

case "$scope" in
  tcr)
    cmd+=(--no-match-path "test/invariant/**")
    cmd+=(--match-contract "^(BudgetTCR|ERC20VotesArbitrator|GeneralizedTCR|SubmissionDepositStrategies|TCRRounds)")
    ;;
  arbitrator)
    cmd+=(--no-match-path "test/invariant/**")
    cmd+=(--match-contract "^ERC20VotesArbitrator")
    ;;
  budget)
    cmd+=(--no-match-path "test/invariant/**")
    cmd+=(--match-contract "^(Budget|FlowBudget)")
    ;;
  flows)
    cmd+=(--no-match-path "test/invariant/**")
    cmd+=(--match-path "test/flows/**")
    ;;
  goals)
    cmd+=(--no-match-path "test/invariant/**")
    cmd+=(--match-path "test/goals/**")
    ;;
  invariant|invariants)
    cmd+=(--match-path "test/invariant/**")
    ;;
  all-lite|lite)
    cmd+=(--no-match-path "test/invariant/**")
    ;;
  *)
    printf 'Error: unknown scope "%s"\n' "$scope" >&2
    usage
    ;;
esac

if is_truthy "$sparse_mode"; then
  exec env FOUNDRY_SPARSE_MODE=true "${cmd[@]}" "$@"
fi
exec "${cmd[@]}" "$@"

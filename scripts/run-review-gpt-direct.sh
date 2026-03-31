#!/usr/bin/env bash

set -euo pipefail

scope="all"
target_bytes="248000"
preset="security"
review_gpt_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    goals|goal|goals-only)
      scope="goals"
      shift
      ;;
    flows|flow|flows-only)
      scope="flows"
      shift
      ;;
    all|combined|ab)
      scope="all"
      shift
      ;;
    [0-9]*)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        target_bytes="$1"
        shift
      else
        echo "Unknown argument: $1"
        echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [--preset <name>] [top-level cobuild-review-gpt flags]"
        exit 1
      fi
      ;;
    --preset)
      preset="${2:?Missing value for --preset}"
      shift 2
      ;;
    --preset=*)
      preset="${1#--preset=}"
      shift
      ;;
    --help|-h)
      echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [--preset <name>] [top-level cobuild-review-gpt flags]"
      exit 0
      ;;
    --)
      shift
      review_gpt_args+=("$@")
      break
      ;;
    --no-send|--dry-run|--send|--submit|--model|--thinking|--chat|--chat-url|--chat-id|--prompt|--prompt-file)
      review_gpt_args+=("$1")
      if [[ "$1" =~ ^--(model|thinking|chat|chat-url|chat-id|prompt|prompt-file)$ ]]; then
        review_gpt_args+=("${2:?Missing value for $1}")
        shift 2
      else
        shift
      fi
      ;;
    --model=*|--thinking=*|--chat=*|--chat-url=*|--chat-id=*|--prompt=*|--prompt-file=*)
      review_gpt_args+=("$1")
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [--preset <name>] [top-level cobuild-review-gpt flags]"
      exit 1
      ;;
  esac
done

case "$scope" in
  goals|goal|goals-only)
    profile="comprehensive-a-goals-logic"
    ;;
  flows|flow|flows-only)
    profile="comprehensive-b-flow-tcr-logic"
    ;;
  all|combined|ab)
    profile="comprehensive-ab-flow-tcr-goals-combined"
    ;;
  *) 
    echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [--preset <name>]" >&2
    echo "Extra top-level cobuild-review-gpt flags are forwarded." >&2
    echo "Scopes: goals, flows, all" >&2
    exit 1
    ;;
esac

cmd=(scripts/run-review-gpt-nozip.sh "$profile" "$target_bytes" --preset "$preset")
if ((${#review_gpt_args[@]} > 0)); then
  cmd+=("${review_gpt_args[@]}")
fi

"${cmd[@]}"

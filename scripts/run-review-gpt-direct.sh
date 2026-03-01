#!/usr/bin/env bash

set -euo pipefail

scope="all"
target_bytes="248000"
preset="security"
preset_set="false"

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
        echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [incentives|security|compliance|...|--preset <name>]"
        exit 1
      fi
      ;;
    --preset)
      preset="${2:?Missing value for --preset}"
      preset_set="true"
      shift 2
      ;;
    --preset=*)
      preset="${1#--preset=}"
      preset_set="true"
      shift
      ;;
    --help|-h)
      echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [incentives|security|compliance|...|--preset <name>]"
      exit 0
      ;;
    *)
      if [[ "$preset_set" == "false" ]]; then
        preset="$1"
        preset_set="true"
        shift
      else
        echo "Unknown argument: $1"
        echo "Usage: scripts/run-review-gpt-direct.sh [goals|flows|all] [target-bytes] [incentives|security|compliance|...|--preset <name>]"
        exit 1
      fi
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
    echo "Scopes: goals, flows, all" >&2
    exit 1
    ;;
esac

scripts/run-review-gpt-nozip.sh "$profile" "$target_bytes" --preset "$preset"

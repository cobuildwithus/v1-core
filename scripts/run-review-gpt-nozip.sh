#!/usr/bin/env bash

set -euo pipefail

PROFILE="${1:-comprehensive-a-goals-logic}"
TARGET_BYTES="${2:-248000}"
PRESET="security"

if [[ $# -gt 0 ]]; then
  case "$1" in
    comprehensive-a-goals-logic|comprehensive-b-flow-tcr-logic|comprehensive-ab-flow-tcr-goals-combined)
      PROFILE="$1"
      shift
      ;;
    --preset)
      PRESET="${2:?Missing value for --preset}"
      shift 2
      ;;
    --preset=*)
      PRESET="${1#--preset=}"
      shift
      ;;
    --help|-h)
      echo "Usage: scripts/run-review-gpt-nozip.sh [profile] [target-bytes] [--preset <name>]"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        TARGET_BYTES="$1"
        shift
      fi
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preset)
      PRESET="${2:?Missing value for --preset}"
      shift 2
      ;;
    --preset=*)
      PRESET="${1#--preset=}"
      shift
      ;;
    --help|-h)
      echo "Usage: scripts/run-review-gpt-nozip.sh [profile] [target-bytes] [--preset <name>]"
      exit 0
      ;;
    [0-9]*)
      TARGET_BYTES="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: scripts/run-review-gpt-nozip.sh [profile] [target-bytes] [--preset <name>]"
      exit 1
      ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

OUT_DIR="${OUT_DIR:-audit-packages}"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/review-gpt-nozip-${PROFILE}-${TARGET_BYTES}.md"

scripts/build-nozip-review-prompt.sh --profile "$PROFILE" --target-bytes "$TARGET_BYTES" --out "$OUT_FILE"
pnpm -s review:gpt -- --no-zip --prompt-file "$ROOT/$OUT_FILE" --preset "$PRESET"

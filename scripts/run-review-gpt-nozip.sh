#!/usr/bin/env bash

set -euo pipefail

PROFILE="${1:-comprehensive-a-goals-logic}"
TARGET_BYTES="${2:-248000}"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

OUT_DIR="${OUT_DIR:-audit-packages}"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/review-gpt-nozip-${PROFILE}-${TARGET_BYTES}.md"

scripts/build-nozip-review-prompt.sh --profile "$PROFILE" --target-bytes "$TARGET_BYTES" --out "$OUT_FILE"
pnpm -s review:gpt -- --prompt-file "$ROOT/$OUT_FILE" --preset security

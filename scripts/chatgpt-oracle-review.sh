#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1-}" = "--" ]; then
  shift
fi
if command -v cobuild-review-gpt >/dev/null 2>&1; then
  exec cobuild-review-gpt --config "$SCRIPT_DIR/review-gpt.config.sh" "$@"
fi
if command -v pnpm >/dev/null 2>&1; then
  exec pnpm exec cobuild-review-gpt --config "$SCRIPT_DIR/review-gpt.config.sh" "$@"
fi

echo "Error: cobuild-review-gpt is not available. Install dependencies first." >&2
exit 1

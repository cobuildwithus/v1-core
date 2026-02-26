#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v slither >/dev/null 2>&1; then
  echo "slither is not installed."
  echo "Install with: pipx install slither-analyzer (or python3 -m pip install --user slither-analyzer)"
  exit 1
fi

slither . \
  --compile-force-framework foundry \
  --foundry-out-directory out \
  --filter-paths "(^lib/|^test/|^node_modules/|src/swaps/CobuildSwap\\.sol$)" \
  --exclude-dependencies \
  --exclude incorrect-equality,uninitialized-local,unused-return \
  --exclude-informational \
  --exclude-low \
  --exclude-optimization \
  "$@"

#!/usr/bin/env bash
set -euo pipefail

COBUILD_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

consumer_shell_path=""
for candidate in \
  "$COBUILD_REPO_ROOT/node_modules/@cobuild/repo-tools/src/consumer-shell.sh" \
  "$COBUILD_REPO_ROOT/../repo-tools/src/consumer-shell.sh"
do
  if [ -f "$candidate" ]; then
    consumer_shell_path="$candidate"
    break
  fi
done

if [ -n "$consumer_shell_path" ]; then
  # shellcheck source=/dev/null
  source "$consumer_shell_path"
else
  repo_tools_join_lines() {
    local out_var="$1"
    shift
    local joined=""
    local item
    for item in "$@"; do
      joined+="${item}"$'\n'
    done
    printf -v "$out_var" '%s' "$joined"
    export "$out_var"
  }

  cobuild_repo_tool_path() {
    local relative_path="$1"
    local local_path="$COBUILD_REPO_ROOT/node_modules/@cobuild/repo-tools/$relative_path"
    local sibling_path="$COBUILD_REPO_ROOT/../repo-tools/$relative_path"

    if [ -f "$local_path" ]; then
      printf '%s\n' "$local_path"
      return 0
    fi

    if [ -f "$sibling_path" ]; then
      printf '%s\n' "$sibling_path"
      return 0
    fi

    echo "Error: missing repo-tools file '$relative_path'. Install dependencies first." >&2
    return 1
  }

  cobuild_repo_tool_bin() {
    local bin_name="$1"
    local local_bin="$COBUILD_REPO_ROOT/node_modules/.bin/$bin_name"
    local sibling_bin="$COBUILD_REPO_ROOT/../repo-tools/bin/$bin_name"

    if [ -x "$local_bin" ]; then
      printf '%s\n' "$local_bin"
      return 0
    fi

    if [ -x "$sibling_bin" ]; then
      printf '%s\n' "$sibling_bin"
      return 0
    fi

    if command -v "$bin_name" >/dev/null 2>&1; then
      command -v "$bin_name"
      return 0
    fi

    echo "Error: missing repo-tools executable '$bin_name'. Install dependencies first." >&2
    return 1
  }
fi

required_files=(
  "agent-docs/index.md"
  "ARCHITECTURE.md"
  "agent-docs/cobuild-protocol-architecture.md"
  "agent-docs/PLANS.md"
  "agent-docs/PRODUCT_SENSE.md"
  "agent-docs/QUALITY_SCORE.md"
  "agent-docs/RELIABILITY.md"
  "agent-docs/SECURITY.md"
  "agent-docs/design-docs/index.md"
  "agent-docs/design-docs/core-beliefs.md"
  "agent-docs/product-specs/index.md"
  "agent-docs/product-specs/protocol-lifecycle-and-invariants.md"
  "agent-docs/references/README.md"
  "agent-docs/references/module-boundary-map.md"
  "agent-docs/references/flow-allocation-and-child-sync-map.md"
  "agent-docs/references/tcr-and-arbitration-map.md"
  "agent-docs/references/goal-funding-and-reward-map.md"
  "agent-docs/references/testing-ci-map.md"
  "agent-docs/references/foundry-llms.txt"
  "agent-docs/references/openzeppelin-upgradeable-llms.txt"
  "agent-docs/references/superfluid-llms.txt"
  "agent-docs/references/bananapus-llms.txt"
  "agent-docs/generated/README.md"
  "agent-docs/exec-plans/active/README.md"
  "agent-docs/exec-plans/completed/README.md"
  "agent-docs/exec-plans/tech-debt-tracker.md"
)
repo_tools_join_lines COBUILD_DRIFT_REQUIRED_FILES "${required_files[@]}"
export COBUILD_DRIFT_CODE_CHANGE_PATTERN='^(src/|test/|foundry\\.toml$|remappings\\.txt$|package\\.json$|ARCHITECTURE\\.md$|\\.husky/pre-commit$|scripts/(check-agent-docs-drift|doc-gardening)\\.sh$|\\.github/workflows/(test|slither|doc-gardening)\\.yml$)'
export COBUILD_DRIFT_CODE_CHANGE_LABEL='Protocol-sensitive code'
export COBUILD_DRIFT_LARGE_CHANGE_THRESHOLD='12'
export COBUILD_DRIFT_CHANGED_COUNT_EXCLUDE_PATTERN='^agent-docs/generated/|^agent-docs/exec-plans/(active|completed)/|^deploys/|^pnpm-lock\\.yaml$'
export COBUILD_DRIFT_ALLOW_RELEASE_ARTIFACTS_ONLY='0'
export COBUILD_COMMITTER_EXAMPLE='fix(protocol): tighten treasury sync guard'
export COBUILD_COMMITTER_DISALLOW_GLOBS=lib/\*$'\n'./lib/\*$'\n'
export COBUILD_AUDIT_CONTEXT_PREFIX='cobuild-protocol-audit'
export COBUILD_AUDIT_CONTEXT_TITLE='Cobuild Protocol Audit Bundle'
export COBUILD_AUDIT_CONTEXT_REPO_LABEL='protocol'
export COBUILD_AUDIT_CONTEXT_INCLUDE_TESTS_DEFAULT='0'
export COBUILD_AUDIT_CONTEXT_INCLUDE_CI_DEFAULT='0'
export COBUILD_AUDIT_CONTEXT_VALIDATE_SOLIDITY_IMPORT_CLOSURE='1'
repo_tools_join_lines COBUILD_AUDIT_CONTEXT_ALWAYS_PATHS \
  "AGENTS.md" \
  "ARCHITECTURE.md" \
  "README.md" \
  "foundry.toml" \
  "remappings.txt" \
  "package.json"
repo_tools_join_lines COBUILD_AUDIT_CONTEXT_SCAN_SPECS \
  "src:*.sol"
repo_tools_join_lines COBUILD_AUDIT_CONTEXT_TEST_SCAN_SPECS \
  "test:*.sol"
repo_tools_join_lines COBUILD_AUDIT_CONTEXT_DOC_SCAN_SPECS \
  "agent-docs:*.md"
repo_tools_join_lines COBUILD_AUDIT_CONTEXT_EXCLUDE_GLOBS \
  "*CobuildSwap*" \
  "*cobuildswap*" \
  "src/interfaces/ICobuildSwap.sol" \
  "src/interfaces/external/uniswap/IUniversalRouter.sol" \
  "src/interfaces/external/uniswap/permit2/IAllowanceTransfer.sol"

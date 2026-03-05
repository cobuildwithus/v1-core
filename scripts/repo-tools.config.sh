#!/usr/bin/env bash
set -euo pipefail

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

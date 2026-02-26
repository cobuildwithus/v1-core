#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

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

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "::error file=$file::Missing required agent-doc artifact."
    exit 1
  fi
done

range=""
changed_files=""

if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
  git fetch --quiet origin "${GITHUB_BASE_REF}" --depth=1 || true
  range="origin/${GITHUB_BASE_REF}...HEAD"
  changed_files="$(git diff --name-only "$range" || true)"
else
  working_tree_changes="$({
    git diff --name-only
    git diff --name-only --cached
    git ls-files --others --exclude-standard
  } | sed '/^[[:space:]]*$/d' | sort -u)"

  if [[ -n "$working_tree_changes" ]]; then
    range="working-tree"
    changed_files="$working_tree_changes"
  elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    range="HEAD~1...HEAD"
    changed_files="$(git diff --name-only "$range" || true)"
  else
    echo "No comparison range available; skipping drift checks."
    exit 0
  fi
fi

if [[ -z "$changed_files" ]]; then
  echo "No changed files detected in $range."
  exit 0
fi

has_change() {
  local pattern="$1"
  echo "$changed_files" | grep -Eq "$pattern"
}

protocol_code_changed=0
docs_changed=0
index_changed=0
active_plan_changed=0
plan_changed=0

if has_change '^(src/|test/|foundry\.toml$|remappings\.txt$|package\.json$|ARCHITECTURE\.md$|\.github/workflows/(test|slither)\.yml$)'; then
  protocol_code_changed=1
fi
if has_change '^agent-docs/'; then
  docs_changed=1
fi
if has_change '^agent-docs/index\.md$'; then
  index_changed=1
fi
if has_change '^agent-docs/exec-plans/active/'; then
  active_plan_changed=1
fi
if has_change '^agent-docs/exec-plans/(active|completed)/'; then
  plan_changed=1
fi

docs_changed_non_generated="$(echo "$changed_files" | grep '^agent-docs/' | grep -Ev '^agent-docs/generated/' || true)"

if (( protocol_code_changed == 1 )) && [[ -z "$docs_changed_non_generated" ]] && (( active_plan_changed == 0 )); then
  echo "::error::Protocol-sensitive code changed without matching non-generated docs or active execution plan updates."
  echo "Update relevant docs in agent-docs/ and/or add an active plan in agent-docs/exec-plans/active/."
  exit 1
fi

if [[ -n "$docs_changed_non_generated" ]] && (( index_changed == 0 )); then
  echo "::error::agent-docs changed (outside generated artifacts) without updating agent-docs/index.md."
  exit 1
fi

changed_count="$(echo "$changed_files" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
if (( changed_count >= 12 )) && (( plan_changed == 0 )); then
  echo "::error::Large change set ($changed_count files) without an active execution plan."
  echo "Add a plan under agent-docs/exec-plans/active/."
  exit 1
fi

echo "Agent docs drift checks passed."

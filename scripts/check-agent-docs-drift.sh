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
compare_source=""
compare_range=""

if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
  git fetch --quiet origin "${GITHUB_BASE_REF}" --depth=1 || true
  range="origin/${GITHUB_BASE_REF}...HEAD"
  changed_files="$(git diff --name-only "$range" || true)"
  compare_source="range"
  compare_range="$range"
else
  staged_changes="$(git diff --name-only --cached | sed '/^[[:space:]]*$/d' | sort -u)"
  working_tree_changes="$({
    git diff --name-only
    git diff --name-only --cached
    git ls-files --others --exclude-standard
  } | sed '/^[[:space:]]*$/d' | sort -u)"

  if [[ -n "$staged_changes" ]]; then
    range="staged"
    changed_files="$staged_changes"
    compare_source="staged"
  elif [[ -n "$working_tree_changes" ]]; then
    range="working-tree"
    changed_files="$working_tree_changes"
    compare_source="working-tree"
  elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    range="HEAD~1...HEAD"
    changed_files="$(git diff --name-only "$range" || true)"
    compare_source="range"
    compare_range="$range"
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

package_json_metadata_only() {
  local before_file after_file status

  before_file="$(mktemp)"
  after_file="$(mktemp)"
  trap 'rm -f "$before_file" "$after_file"' RETURN

  case "$compare_source" in
    staged)
      git show HEAD:package.json >"$before_file" 2>/dev/null || printf '{}\n' >"$before_file"
      git show :package.json >"$after_file" 2>/dev/null || printf '{}\n' >"$after_file"
      ;;
    working-tree)
      git show HEAD:package.json >"$before_file" 2>/dev/null || printf '{}\n' >"$before_file"
      cat package.json >"$after_file" 2>/dev/null || printf '{}\n' >"$after_file"
      ;;
    range)
      git show "$(git merge-base "${compare_range%...HEAD}" HEAD)":package.json >"$before_file" 2>/dev/null || printf '{}\n' >"$before_file"
      git show HEAD:package.json >"$after_file" 2>/dev/null || printf '{}\n' >"$after_file"
      ;;
    *)
      rm -f "$before_file" "$after_file"
      trap - RETURN
      return 1
      ;;
  esac

  node - "$before_file" "$after_file" <<'EOF'
const fs = require("node:fs");
const [beforePath, afterPath] = process.argv.slice(2);
const allowed = new Set([
  "version",
  "packageManager",
  "dependencies",
  "devDependencies",
  "peerDependencies",
  "optionalDependencies",
  "peerDependenciesMeta",
  "overrides",
  "resolutions",
  "engines",
  "pnpm",
]);

const before = JSON.parse(fs.readFileSync(beforePath, "utf8"));
const after = JSON.parse(fs.readFileSync(afterPath, "utf8"));
const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
const changed = [...keys].filter((key) => JSON.stringify(before[key]) !== JSON.stringify(after[key]));

if (changed.length === 0 || changed.some((key) => !allowed.has(key))) {
  process.exit(1);
}
EOF
  status=$?

  rm -f "$before_file" "$after_file"
  trap - RETURN
  return "$status"
}

exec_plan_support_pattern='^agent-docs/exec-plans/(active/COORDINATION_LEDGER\.md|(active|completed)/README\.md)$'
active_plan_changes="$(echo "$changed_files" | grep '^agent-docs/exec-plans/active/' | grep -Ev "$exec_plan_support_pattern" || true)"
plan_changes="$(echo "$changed_files" | grep '^agent-docs/exec-plans/(active|completed)/' | grep -Ev "$exec_plan_support_pattern" || true)"

protocol_code_changed=0
index_changed=0
active_plan_changed=0
plan_changed=0
package_metadata_only_changed=0

if has_change '^(src/|test/|foundry\.toml$|remappings\.txt$|package\.json$|ARCHITECTURE\.md$|\.husky/pre-commit$|scripts/(check-agent-docs-drift|doc-gardening)\.sh$|\.github/workflows/(test|slither|doc-gardening)\.yml$)'; then
  protocol_code_changed=1
fi
if has_change '^agent-docs/index\.md$'; then
  index_changed=1
fi
if [[ -n "$active_plan_changes" ]]; then
  active_plan_changed=1
fi
if [[ -n "$plan_changes" ]]; then
  plan_changed=1
fi

docs_changed_non_generated="$(echo "$changed_files" | grep '^agent-docs/' | grep -Ev '^agent-docs/generated/' || true)"
docs_changed_requiring_index="$(echo "$docs_changed_non_generated" | grep -Ev '^agent-docs/exec-plans/(active|completed)/' || true)"

if has_change '^package\.json$'; then
  non_package_metadata_changes="$(echo "$changed_files" | grep -Ev '^(package\.json|pnpm-lock\.yaml)$' || true)"
  if [[ -z "$non_package_metadata_changes" ]] && package_json_metadata_only; then
    package_metadata_only_changed=1
  fi
fi

if (( protocol_code_changed == 1 )) && [[ -z "$docs_changed_non_generated" ]] && (( active_plan_changed == 0 )) && (( package_metadata_only_changed == 0 )); then
  echo "::error::Protocol-sensitive code changed without matching non-generated docs or active execution plan updates."
  echo "Update relevant docs in agent-docs/ and/or add an active plan in agent-docs/exec-plans/active/."
  exit 1
fi

if [[ -n "$docs_changed_requiring_index" ]] && (( index_changed == 0 )); then
  echo "::error::agent-docs changed (outside generated artifacts) without updating agent-docs/index.md."
  exit 1
fi

changed_count="$(printf '%s\n' "$changed_files" \
  | awk '!/^agent-docs\/generated\// && !/^agent-docs\/exec-plans\/(active|completed)\// && !/^deploys\// && !/^pnpm-lock\.yaml$/ && NF { count++ } END { print count + 0 }')"
if (( changed_count >= 12 && plan_changed == 0 )); then
  echo "::error::Large change set ($changed_count files) without an active execution plan."
  echo "Add a plan under agent-docs/exec-plans/active/."
  exit 1
fi

echo "Agent docs drift checks passed."

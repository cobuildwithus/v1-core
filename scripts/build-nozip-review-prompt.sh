#!/usr/bin/env bash

set -euo pipefail

profile="single-balanced-250"
target_bytes=250000
out_path=""
list_profiles_only=0

usage() {
  cat <<'EOF'
Usage: scripts/build-nozip-review-prompt.sh [options]

Build a no-zip markdown payload for manual GPT review paste/upload.
The script strips Solidity comments/blank lines and enforces a hard byte cap.

Options:
  --profile <name>        Profile to build (default: single-balanced-250)
  --target-bytes <n>      Max output bytes (default: 250000)
  --out <path>            Output path (default: audit-packages/review-gpt-nozip-<profile>-<utc>.md)
  --list-profiles         Print available profile names and exit
  -h, --help              Show this help text

Examples:
  scripts/build-nozip-review-prompt.sh
  scripts/build-nozip-review-prompt.sh --profile comprehensive-a-goals-logic
  scripts/build-nozip-review-prompt.sh --profile comprehensive-b-flow-tcr-logic --target-bytes 250000

Note:
  CobuildSwap is intentionally excluded from these comprehensive profiles for now (non-core scope).
EOF
}

list_profiles() {
  cat <<'EOF'
single-balanced-250
comprehensive-a-goals-logic
comprehensive-b-flow-tcr-logic
comprehensive-ab-flow-tcr-goals-combined
EOF
}

strip_solidity() {
  local abs_path="$1"
  perl -0777 -pe 's!/\*.*?\*/!!gs; s!//.*$!!gm; s!^[[:space:]]*import[[:space:]].*?;\s*\n!!mg; s/^[[:space:]]+//mg; s/[[:space:]]+/ /g; s/[ \t]*\n[ \t]*/\n/g; s/\belse\s+if\b/else if/g; s/\s*([(),{}\[\];:])\s*/$1/g; s/\s*(==|!=|<=|>=|<<|>>|\+=|-=|\*=|\/=|%=|\|=|&=|\^=|&&|\|\||<<=|>>=|->|[-+*\/%<>&|\^!:?=])\s*/$1/g; s/\}\s*else/}else/g' "$abs_path" | sed '/^[[:space:]]*$/d'
}

emit_profile_files() {
  local selected="$1"
  case "$selected" in
    single-balanced-250)
      cat <<'EOF'
src/goals/GoalTreasury.sol
src/goals/BudgetTreasury.sol
src/goals/StakeVault.sol
src/goals/RewardEscrow.sol
src/hooks/GoalRevnetSplitHook.sol
src/goals/TreasuryBase.sol
src/goals/library/TreasurySuccessAssertions.sol
src/goals/library/TreasuryFlowRateSync.sol
src/goals/library/RewardEscrowMath.sol
src/goals/library/StakeVaultRentMath.sol
src/goals/library/StakeVaultJurorMath.sol
src/goals/library/StakeVaultSlashMath.sol
src/goals/library/TreasuryDonations.sol
src/goals/library/GoalSpendPatterns.sol
src/tcr/GeneralizedTCR.sol
src/tcr/ERC20VotesArbitrator.sol
src/tcr/BudgetTCR.sol
src/tcr/storage/GeneralizedTCRStorageV1.sol
src/tcr/storage/ArbitratorStorageV1.sol
src/tcr/storage/BudgetTCRStorageV1.sol
src/tcr/library/TCRRounds.sol
src/tcr/utils/VotingTokenCompatibility.sol
src/tcr/utils/ArbitrationCostExtraData.sol
src/tcr/utils/CappedMath.sol
src/Flow.sol
src/flows/CustomFlow.sol
src/storage/FlowStorage.sol
src/library/FlowAllocations.sol
src/library/FlowRates.sol
src/library/FlowRecipients.sol
src/library/FlowInitialization.sol
src/library/FlowPools.sol
src/library/AllocationSnapshot.sol
EOF
      ;;
    comprehensive-a-goals-logic)
      cat <<'EOF'
src/goals/GoalTreasury.sol
src/goals/BudgetTreasury.sol
src/goals/StakeVault.sol
src/goals/RewardEscrow.sol
src/goals/BudgetStakeLedger.sol
src/goals/TreasuryBase.sol
src/goals/UMATreasurySuccessResolver.sol
src/hooks/GoalRevnetSplitHook.sol
src/goals/library/BudgetStakeLedgerMath.sol
src/goals/library/GoalSpendPatterns.sol
src/goals/library/StakeVaultJurorMath.sol
src/goals/library/StakeVaultRentMath.sol
src/goals/library/StakeVaultSlashMath.sol
src/goals/library/RewardEscrowMath.sol
src/goals/library/TreasuryDonations.sol
src/goals/library/TreasuryFlowRateSync.sol
src/goals/library/TreasurySuccessAssertions.sol
src/tcr/BudgetTCR.sol
src/tcr/GeneralizedTCR.sol
src/tcr/BudgetTCRDeployer.sol
src/library/AllocationCommitment.sol
src/library/CustomFlowPreviousState.sol
src/library/FlowProtocolConstants.sol
src/library/FlowSets.sol
src/library/AllocationSnapshot.sol
src/library/FlowUnitMath.sol
src/library/SortedRecipientMerge.sol
src/tcr/library/BudgetTCRItems.sol
src/tcr/library/TCRRounds.sol
src/tcr/storage/ArbitratorStorageV1.sol
src/tcr/storage/BudgetTCRStorageV1.sol
src/tcr/storage/GeneralizedTCRStorageV1.sol
src/tcr/utils/ArbitrationCostExtraData.sol
src/tcr/utils/CappedMath.sol
src/tcr/utils/VotingTokenCompatibility.sol
src/tcr/BudgetTCRFactory.sol
src/tcr/library/BudgetTCRValidationLib.sol
src/tcr/library/BudgetTCRStackDeploymentLib.sol
src/tcr/strategies/EscrowSubmissionDepositStrategy.sol
src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol
src/allocation-strategies/AddressKeyAllocationStrategy.sol
src/allocation-strategies/BudgetStakeStrategy.sol
src/library/CustomFlowAllocationEngine.sol
src/library/CustomFlowLibrary.sol
src/library/CustomFlowPreview.sol
src/library/CustomFlowPreviousState.sol
src/library/CustomFlowRuntimeHelpers.sol
src/Flow.sol
src/flows/CustomFlow.sol
src/storage/FlowStorage.sol
src/library/FlowAllocations.sol
src/library/FlowRates.sol
src/library/FlowRecipients.sol
EOF
      ;;
    comprehensive-b-flow-tcr-logic)
      cat <<'EOF'
src/Flow.sol
src/flows/CustomFlow.sol
src/storage/FlowStorage.sol
src/hooks/GoalFlowAllocationLedgerPipeline.sol
src/library/AllocationCommitment.sol
src/library/AllocationSnapshot.sol
src/library/CustomFlowAllocationEngine.sol
src/library/CustomFlowLibrary.sol
src/library/CustomFlowPreview.sol
src/library/CustomFlowPreviousState.sol
src/library/CustomFlowRuntimeHelpers.sol
src/library/FlowAllocations.sol
src/library/FlowInitialization.sol
src/library/FlowPools.sol
src/library/FlowProtocolConstants.sol
src/library/FlowRates.sol
src/library/FlowRecipients.sol
src/library/FlowSets.sol
src/library/FlowUnitMath.sol
src/library/GoalFlowLedgerMode.sol
src/library/SortedRecipientMerge.sol
src/allocation-strategies/AddressKeyAllocationStrategy.sol
src/allocation-strategies/BudgetStakeStrategy.sol
src/tcr/BudgetTCR.sol
src/tcr/BudgetTCRDeployer.sol
src/tcr/BudgetTCRFactory.sol
src/tcr/library/BudgetTCRValidationLib.sol
src/tcr/ERC20VotesArbitrator.sol
src/tcr/GeneralizedTCR.sol
src/tcr/library/BudgetTCRItems.sol
src/tcr/library/BudgetTCRStackDeploymentLib.sol
src/tcr/library/TCRRounds.sol
src/library/GoalFlowLedgerMode.sol
src/tcr/storage/ArbitratorStorageV1.sol
src/tcr/storage/BudgetTCRStorageV1.sol
src/tcr/storage/GeneralizedTCRStorageV1.sol
src/tcr/strategies/EscrowSubmissionDepositStrategy.sol
src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol
src/goals/library/StakeVaultJurorMath.sol
src/goals/library/StakeVaultRentMath.sol
src/goals/RewardEscrow.sol
src/goals/library/StakeVaultSlashMath.sol
src/goals/TreasuryBase.sol
src/goals/BudgetTreasury.sol
src/goals/library/GoalSpendPatterns.sol
src/goals/library/RewardEscrowMath.sol
src/goals/library/BudgetStakeLedgerMath.sol
src/goals/library/TreasuryFlowRateSync.sol
src/goals/library/TreasuryDonations.sol
src/goals/library/TreasurySuccessAssertions.sol
src/tcr/utils/ArbitrationCostExtraData.sol
src/tcr/utils/CappedMath.sol
src/tcr/utils/VotingTokenCompatibility.sol
src/goals/UMATreasurySuccessResolver.sol
src/hooks/GoalRevnetSplitHook.sol
src/storage/FlowStorage.sol
EOF
      ;;
    comprehensive-ab-flow-tcr-goals-combined)
      cat <<'EOF'
src/Flow.sol
src/flows/CustomFlow.sol
src/storage/FlowStorage.sol
src/hooks/GoalFlowAllocationLedgerPipeline.sol
src/library/AllocationCommitment.sol
src/library/AllocationSnapshot.sol
src/library/CustomFlowAllocationEngine.sol
src/library/CustomFlowLibrary.sol
src/library/CustomFlowPreview.sol
src/library/CustomFlowPreviousState.sol
src/library/CustomFlowRuntimeHelpers.sol
src/library/FlowAllocations.sol
src/library/FlowInitialization.sol
src/library/FlowPools.sol
src/library/FlowProtocolConstants.sol
src/library/FlowRates.sol
src/library/FlowRecipients.sol
src/library/FlowSets.sol
src/library/FlowUnitMath.sol
src/library/GoalFlowLedgerMode.sol
src/library/SortedRecipientMerge.sol
src/allocation-strategies/AddressKeyAllocationStrategy.sol
src/allocation-strategies/BudgetStakeStrategy.sol
src/tcr/BudgetTCR.sol
src/tcr/BudgetTCRDeployer.sol
src/tcr/BudgetTCRFactory.sol
src/tcr/library/BudgetTCRValidationLib.sol
src/tcr/GeneralizedTCR.sol
src/tcr/library/BudgetTCRItems.sol
src/tcr/library/BudgetTCRStackDeploymentLib.sol
src/tcr/library/TCRRounds.sol
src/tcr/storage/ArbitratorStorageV1.sol
src/tcr/storage/BudgetTCRStorageV1.sol
src/tcr/storage/GeneralizedTCRStorageV1.sol
src/tcr/strategies/EscrowSubmissionDepositStrategy.sol
src/tcr/strategies/PrizePoolSubmissionDepositStrategy.sol
src/goals/RewardEscrow.sol
src/goals/TreasuryBase.sol
src/goals/BudgetTreasury.sol
src/goals/library/GoalSpendPatterns.sol
src/goals/library/TreasuryDonations.sol
src/goals/library/TreasurySuccessAssertions.sol
src/tcr/utils/ArbitrationCostExtraData.sol
src/tcr/utils/CappedMath.sol
src/tcr/utils/VotingTokenCompatibility.sol
src/goals/UMATreasurySuccessResolver.sol
src/goals/library/StakeVaultJurorMath.sol
src/goals/library/StakeVaultRentMath.sol
src/goals/library/StakeVaultSlashMath.sol
src/goals/library/BudgetStakeLedgerMath.sol
src/goals/library/RewardEscrowMath.sol
src/goals/GoalTreasury.sol
src/goals/StakeVault.sol
src/hooks/GoalRevnetSplitHook.sol
EOF
      ;;
    *)
      echo "Error: unknown profile '$selected'." >&2
      echo "Run with --list-profiles to view valid values." >&2
      exit 1
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then
    shift
    continue
  fi
  case "$1" in
    --profile)
      if [ "$#" -lt 2 ]; then
        echo "Error: --profile requires a value." >&2
        exit 1
      fi
      profile="$2"
      shift 2
      ;;
    --target-bytes)
      if [ "$#" -lt 2 ]; then
        echo "Error: --target-bytes requires a value." >&2
        exit 1
      fi
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --target-bytes must be a positive integer." >&2
        exit 1
      fi
      target_bytes="$2"
      shift 2
      ;;
    --out)
      if [ "$#" -lt 2 ]; then
        echo "Error: --out requires a value." >&2
        exit 1
      fi
      out_path="$2"
      shift 2
      ;;
    --list-profiles)
      list_profiles_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option '$1'." >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ "$list_profiles_only" -eq 1 ]; then
  list_profiles
  exit 0
fi

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "Error: not inside a git repository." >&2
  exit 1
fi

if [ -z "$out_path" ]; then
  timestamp="$(date -u '+%Y%m%d-%H%M%SZ')"
  out_path="$ROOT/audit-packages/review-gpt-nozip-${profile}-${timestamp}.md"
elif [[ "$out_path" != /* ]]; then
  out_path="$PWD/$out_path"
fi

mkdir -p "$(dirname "$out_path")"

manifest="$(mktemp)"
included_manifest="$(mktemp)"
skipped_manifest="$(mktemp)"
block_file="$(mktemp)"
cleanup() {
  rm -f "$manifest" "$included_manifest" "$skipped_manifest" "$block_file"
}
trap cleanup EXIT

emit_profile_files "$profile" | while IFS= read -r relpath; do
  relpath="$(printf '%s' "$relpath" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$relpath" ]; then
    continue
  fi
  if [ ! -f "$ROOT/$relpath" ]; then
    echo "Warning: skipping missing profile file: $relpath" >&2
    continue
  fi
  if ! grep -Fxq "$relpath" "$manifest"; then
    echo "$relpath" >> "$manifest"
  fi
done

if [ ! -s "$manifest" ]; then
  echo "Error: profile '$profile' resolved to 0 valid files." >&2
  exit 1
fi

{
  echo "# Review GPT No-ZIP Payload"
  echo
  echo "profile: $profile"
  echo "target_bytes: $target_bytes"
  echo "generated_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo
  echo "---"
} > "$out_path"

while IFS= read -r relpath; do
  abs_path="$ROOT/$relpath"
  {
    echo
    echo "## File: $relpath"
    echo '```solidity'
    strip_solidity "$abs_path"
    echo '```'
  } > "$block_file"

  block_bytes="$(wc -c < "$block_file" | tr -d ' ')"
  current_bytes="$(wc -c < "$out_path" | tr -d ' ')"
  if [ $((current_bytes + block_bytes)) -le "$target_bytes" ]; then
    cat "$block_file" >> "$out_path"
    printf '%s|%s\n' "$relpath" "$block_bytes" >> "$included_manifest"
  else
    printf '%s|%s\n' "$relpath" "$block_bytes" >> "$skipped_manifest"
  fi
done < "$manifest"

final_bytes="$(wc -c < "$out_path" | tr -d ' ')"
included_count=0
skipped_count=0
if [ -s "$included_manifest" ]; then
  included_count="$(wc -l < "$included_manifest" | tr -d ' ')"
fi
if [ -s "$skipped_manifest" ]; then
  skipped_count="$(wc -l < "$skipped_manifest" | tr -d ' ')"
fi

echo "OUTPUT: $out_path"
echo "BYTES: $final_bytes"
echo "PROFILE: $profile"
echo "TARGET_BYTES: $target_bytes"
echo "INCLUDED_FILES: $included_count"
echo "SKIPPED_FILES: $skipped_count"
if [ "$skipped_count" -gt 0 ]; then
  echo "Skipped due to byte cap (in priority order):"
  while IFS='|' read -r relpath block_bytes; do
    printf '  - %s (%s bytes)\n' "$relpath" "$block_bytes"
  done < "$skipped_manifest"
fi

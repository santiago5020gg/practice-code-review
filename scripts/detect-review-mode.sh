#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

echo "::group::Review Mode Detection"

review_mode="full"
track1_files_json="[]"
track2_files_json="[]"
prior_violations_json="[]"
untouched_violations_json="[]"

can_incremental=true

if [[ "${GITHUB_EVENT_ACTION:-}" != "synchronize" ]]; then
  echo "Not synchronize event (action=${GITHUB_EVENT_ACTION:-unknown}) → FULL"
  can_incremental=false
fi

if [[ "$can_incremental" == "true" ]]; then
  if [[ "${BEFORE_SHA:-}" =~ ^0+$ ]] || [[ -z "${BEFORE_SHA:-}" ]]; then
    echo "BEFORE_SHA is zero/empty → FULL"
    can_incremental=false
  fi
fi

if [[ "$can_incremental" == "true" ]]; then
  if ! git merge-base --is-ancestor "$BEFORE_SHA" "$AFTER_SHA" 2>/dev/null; then
    echo "BEFORE_SHA is not ancestor of AFTER_SHA (force-push/rebase) → FULL"
    can_incremental=false
  fi
fi

if [[ "$can_incremental" == "true" ]]; then
  if [[ ! -f "$ARTIFACT_FILE" ]]; then
    echo "No prior artifact found → FULL"
    can_incremental=false
  elif ! jq -e '.active_violations' "$ARTIFACT_FILE" > /dev/null 2>&1; then
    echo "Prior artifact is invalid JSON → FULL"
    can_incremental=false
  fi
fi

if [[ "$can_incremental" == "true" ]]; then
  violations_count=$(jq '.active_violations | length' "$ARTIFACT_FILE")
  if [[ "$violations_count" -eq 0 ]]; then
    echo "Prior artifact has 0 violations → FULL"
    can_incremental=false
  fi
fi

if [[ "$can_incremental" == "true" ]]; then
  review_mode="incremental"
  echo "All conditions met → INCREMENTAL"

  changed_files=$(git diff --name-only --diff-filter=ACMR "$BEFORE_SHA".."$AFTER_SHA" | filter_code_files || true)
  deleted_files=$(git diff --name-only --diff-filter=D "$BEFORE_SHA".."$AFTER_SHA" || true)

  all_prior=$(jq -c '.active_violations' "$ARTIFACT_FILE")

  if [[ -n "$deleted_files" ]]; then
    delete_filter=$(echo "$deleted_files" | jq -R -s 'split("\n") | map(select(length > 0))')
    all_prior=$(echo "$all_prior" | jq --argjson del "$delete_filter" '[.[] | select(.path as $p | ($del | index($p)) == null)]')
    echo "Auto-resolved violations on deleted files"
  fi

  prior_paths=$(echo "$all_prior" | jq -r '.[].path' | sort -u)

  track1_list=""
  track2_list=""
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if echo "$prior_paths" | grep -qx "$file"; then
      track1_list="${track1_list}${file}"$'\n'
    else
      track2_list="${track2_list}${file}"$'\n'
    fi
  done <<< "$changed_files"

  track1_files_json=$(echo "$track1_list" | jq -R -s 'split("\n") | map(select(length > 0))')
  track2_files_json=$(echo "$track2_list" | jq -R -s 'split("\n") | map(select(length > 0))')

  prior_violations_json=$(echo "$all_prior" | jq --argjson t1 "$track1_files_json" '[.[] | select(.path as $p | ($t1 | index($p)) != null)]')

  all_changed_json=$(echo "$changed_files" | jq -R -s 'split("\n") | map(select(length > 0))')
  untouched_violations_json=$(echo "$all_prior" | jq --argjson changed "$all_changed_json" '[.[] | select(.path as $p | ($changed | index($p)) == null)]')

else
  changed_files=$(git diff --name-only --diff-filter=ACMR "origin/${BASE_REF:-main}...HEAD" | filter_code_files || true)
fi

code_files_json=$(echo "$changed_files" | jq -R -s 'split("\n") | map(select(length > 0))')

echo "::endgroup::"

echo "review_mode=$review_mode" >> "$GITHUB_OUTPUT"
echo "code_files_json<<EOF" >> "$GITHUB_OUTPUT"
echo "$code_files_json" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"
echo "track1_files_json<<EOF" >> "$GITHUB_OUTPUT"
echo "$track1_files_json" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"
echo "track2_files_json<<EOF" >> "$GITHUB_OUTPUT"
echo "$track2_files_json" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"
echo "prior_violations_json<<EOF" >> "$GITHUB_OUTPUT"
echo "$prior_violations_json" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"
echo "untouched_violations_json<<EOF" >> "$GITHUB_OUTPUT"
echo "$untouched_violations_json" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"

echo "Review mode: $review_mode"
echo "Code files: $(echo "$code_files_json" | jq 'length')"
if [[ "$review_mode" == "incremental" ]]; then
  echo "Track 1 files: $(echo "$track1_files_json" | jq 'length')"
  echo "Track 2 files: $(echo "$track2_files_json" | jq 'length')"
  echo "Untouched violations: $(echo "$untouched_violations_json" | jq 'length')"
fi

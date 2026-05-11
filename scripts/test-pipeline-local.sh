#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

BASE_BRANCH="${1:-main}"
HEAD_SHA=$(git rev-parse HEAD)
PR_NUMBER="local-test"

echo "=== PR Code Review — Local Test ==="
echo "Base: $BASE_BRANCH"
echo "Head: $HEAD_SHA"
echo ""

if ! command -v claude &> /dev/null; then
  echo "ERROR: Claude Code CLI not found. Install with: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "ERROR: jq not found. Install with: sudo apt-get install jq"
  exit 1
fi

if [[ ! -d ".claude/skills" ]] || [[ -z "$(ls -A .claude/skills/ 2>/dev/null | grep -v .gitkeep)" ]]; then
  echo "WARNING: No skills found in .claude/skills/ — pipeline will find no violations"
fi

export REVIEW_MODE="full"
export HEAD_SHA
export PR_NUMBER
export BASE_REF="$BASE_BRANCH"

changed_files=$(git diff --name-only --diff-filter=ACMR "origin/${BASE_BRANCH}...HEAD" 2>/dev/null || \
                git diff --name-only --diff-filter=ACMR "${BASE_BRANCH}...HEAD" 2>/dev/null || \
                git diff --name-only --diff-filter=ACMR HEAD~1 2>/dev/null || echo "")

code_files=$(echo "$changed_files" | while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  ext="${f##*.}"
  for code_ext in $CODE_EXTENSIONS; do
    if [[ "$ext" == "$code_ext" ]]; then
      echo "$f"
      break
    fi
  done
done)

export CODE_FILES_JSON=$(echo "$code_files" | jq -R -s 'split("\n") | map(select(length > 0))')
export TRACK1_FILES_JSON="[]"
export TRACK2_FILES_JSON="[]"
export PRIOR_VIOLATIONS_JSON="[]"
export UNTOUCHED_VIOLATIONS_JSON="[]"
export PUSH_COUNT="1"

echo "Code files to review:"
echo "$CODE_FILES_JSON" | jq -r '.[]'
echo ""

echo "=== Running Pipeline ==="
mkdir -p "$ARTIFACT_DIR"
bash "$SCRIPT_DIR/run-review-pipeline.sh"

echo ""
echo "=== Results ==="
if [[ -f "$ARTIFACT_DIR/pipeline-output.json" ]]; then
  echo "Verdict: $(jq -r '.verdict' "$ARTIFACT_DIR/pipeline-output.json")"
  echo "Violations: $(jq '.stats.violations_found // 0' "$ARTIFACT_DIR/pipeline-output.json")"
  echo ""
  echo "Full output:"
  jq '.' "$ARTIFACT_DIR/pipeline-output.json"
else
  echo "ERROR: No output produced"
  exit 1
fi

#!/usr/bin/env bash
# scripts/lib/common.sh

set -euo pipefail

# Marker used to identify bot reviews/comments for cleanup
readonly REVIEW_MARKER="<!-- pr-code-review-validator -->"

# File extensions considered "code" (everything else is skipped)
readonly CODE_EXTENSIONS="ts tsx js jsx prisma sql"

# Timeouts (seconds)
readonly TIMEOUT_FULL_PIPELINE=540
readonly TIMEOUT_TRACK1_VERIFY=180

# Artifact paths
readonly ARTIFACT_DIR=".review-artifacts"
readonly ARTIFACT_FILE="${ARTIFACT_DIR}/violations.json"

# Models
readonly MODEL_CLASSIFY="us.anthropic.claude-haiku-4-5-20251001-v1:0"
readonly MODEL_VALIDATE="us.anthropic.claude-sonnet-4-6"
readonly MODEL_SYNTHESIZE="us.anthropic.claude-opus-4-6-v1"

# Returns 0 if the file has a code extension, 1 otherwise
is_code_file() {
  local file="${1:-}"
  [[ -z "$file" ]] && return 1
  local ext="${file##*.}"
  [[ "$file" == "$ext" ]] && return 1
  for code_ext in $CODE_EXTENSIONS; do
    if [[ "$ext" == "$code_ext" ]]; then
      return 0
    fi
  done
  return 1
}

# Filters a newline-delimited list of files to only code files
filter_code_files() {
  while IFS= read -r file; do
    if is_code_file "$file"; then
      echo "$file"
    fi
  done
}

# GitHub Code Review Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a GitHub Actions pipeline that automatically reviews PRs using a multi-agent Claude pipeline (Haiku classifies, Sonnet validates, Opus synthesizes), posts bundled reviews with inline comments, and supports incremental re-validation on subsequent pushes.

**Architecture:** GitHub Actions workflow triggers on PR events, runs 4 shell scripts in sequence: detect review mode, cleanup prior reviews, run multi-agent pipeline (via Claude Code CLI), post bundled review. State persists between pushes via GitHub Actions artifacts. All domain logic lives in skill files — infrastructure scripts are skill-agnostic.

**Tech Stack:** GitHub Actions, Bash, Claude Code CLI (`@anthropic-ai/claude-code`), `gh` CLI, `jq`, Portkey gateway to AWS Bedrock (Claude Haiku/Sonnet/Opus)

---

## File Structure

```
.github/
  workflows/
    pr-code-review-validator.yml       — GitHub Actions workflow definition

scripts/
  lib/
    json-extract.sh                    — Multi-strategy JSON extraction from CLI output
    common.sh                          — Shared constants (marker, file extensions, timeouts)
  detect-review-mode.sh                — Determines FULL vs INCREMENTAL mode
  cleanup-prior-reviews.sh             — Dismisses/minimizes prior bot reviews
  run-review-pipeline.sh               — Orchestrates the 3-stage AI pipeline
  post-review.sh                       — Posts bundled review to GitHub + writes artifact

prompts/
  pipeline-full.md                     — Full-mode prompt template (3-stage pipeline)
  pipeline-incremental-track2.md       — Track 2 prompt (scoped full pipeline)
  verification-track1.md               — Track 1 prompt (re-verify prior violations)

.claude/
  skills/                              — (empty dir, ready for skills to be added)
```

---

## Task 1: Shared Library — `common.sh`

**Files:**
- Create: `scripts/lib/common.sh`

- [ ] **Step 1: Create the shared constants file**

```bash
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
readonly MODEL_CLASSIFY="haiku"
readonly MODEL_VALIDATE="sonnet"
readonly MODEL_SYNTHESIZE="opus"

# Returns 0 if the file has a code extension, 1 otherwise
is_code_file() {
  local file="$1"
  local ext="${file##*.}"
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
```

- [ ] **Step 2: Verify the script is syntactically valid**

Run: `bash -n scripts/lib/common.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/common.sh
git commit -m "feat: add shared constants library for review pipeline"
```

---

## Task 2: Shared Library — `json-extract.sh`

**Files:**
- Create: `scripts/lib/json-extract.sh`

- [ ] **Step 1: Create the multi-strategy JSON extraction script**

This implements the 4-strategy extraction from Claude CLI output (Criterion 7: Output Format Resilience).

```bash
#!/usr/bin/env bash
# scripts/lib/json-extract.sh
#
# Extracts structured JSON from Claude Code CLI output.
# The CLI may return JSON in several formats depending on model/version:
#   1. Direct JSON (the entire output is valid JSON with expected keys)
#   2. Envelope with .result field containing the actual JSON
#   3. Content blocks array (messages API format)
#   4. JSON embedded in text (markdown code fences or inline)
#
# Usage: extract_json <raw_output_file> <output_file>
# Returns 0 on success, 1 if no strategy succeeded.

set -euo pipefail

extract_json() {
  local raw_file="$1"
  local out_file="$2"

  # Strategy 1: Direct JSON — entire file is valid JSON with "verdict" or top-level array
  if jq -e 'if type == "array" then true elif .verdict then true else false end' "$raw_file" > /dev/null 2>&1; then
    cp "$raw_file" "$out_file"
    return 0
  fi

  # Strategy 2: Envelope with .result field
  if jq -e '.result' "$raw_file" > /dev/null 2>&1; then
    local result_type
    result_type=$(jq -r '.result | type' "$raw_file")
    if [[ "$result_type" == "string" ]]; then
      # .result is a JSON string that needs parsing
      jq -r '.result' "$raw_file" | jq '.' > "$out_file" 2>/dev/null && return 0
    else
      # .result is already an object/array
      jq '.result' "$raw_file" > "$out_file"
      return 0
    fi
  fi

  # Strategy 3: Content blocks array (messages API format)
  if jq -e '.content[0].text' "$raw_file" > /dev/null 2>&1; then
    local text
    text=$(jq -r '.content[0].text' "$raw_file")
    echo "$text" | jq '.' > "$out_file" 2>/dev/null && return 0
    # If the text itself isn't JSON, try extracting from code fences
    local fenced
    fenced=$(echo "$text" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
    if [[ -n "$fenced" ]]; then
      echo "$fenced" | jq '.' > "$out_file" 2>/dev/null && return 0
    fi
  fi

  # Strategy 4: Embedded JSON in text (find first { or [ that parses)
  local content
  content=$(cat "$raw_file")
  # Try extracting from markdown code fences first
  local fenced
  fenced=$(echo "$content" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -n "$fenced" ]]; then
    echo "$fenced" | jq '.' > "$out_file" 2>/dev/null && return 0
  fi
  # Try finding JSON starting from first { or [
  local first_brace first_bracket start
  first_brace=$(echo "$content" | grep -n '{' | head -1 | cut -d: -f1)
  first_bracket=$(echo "$content" | grep -n '\[' | head -1 | cut -d: -f1)
  if [[ -n "$first_brace" && -n "$first_bracket" ]]; then
    start=$((first_brace < first_bracket ? first_brace : first_bracket))
  elif [[ -n "$first_brace" ]]; then
    start=$first_brace
  elif [[ -n "$first_bracket" ]]; then
    start=$first_bracket
  else
    return 1
  fi
  echo "$content" | tail -n +"$start" | jq '.' > "$out_file" 2>/dev/null && return 0

  return 1
}
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n scripts/lib/json-extract.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/json-extract.sh
git commit -m "feat: add multi-strategy JSON extraction for CLI output"
```

---

## Task 3: Review Mode Detection — `detect-review-mode.sh`

**Files:**
- Create: `scripts/detect-review-mode.sh`

- [ ] **Step 1: Create the review mode detection script**

```bash
#!/usr/bin/env bash
# scripts/detect-review-mode.sh
#
# Determines whether to run a FULL or INCREMENTAL review.
# Outputs environment variables via $GITHUB_OUTPUT:
#   review_mode=full|incremental
#   code_files_json=<JSON array of code files in diff>
#   track1_files_json=<JSON array of Track 1 files (have prior violations)>
#   track2_files_json=<JSON array of Track 2 files (no prior violations)>
#   prior_violations_json=<JSON of prior violations for Track 1>
#   untouched_violations_json=<JSON array of violations on untouched files>
#
# Required env vars: GITHUB_EVENT_ACTION, BEFORE_SHA, AFTER_SHA, PR_NUMBER
# Required files: .review-artifacts/violations.json (optional, for incremental)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

echo "::group::Review Mode Detection"

# Default: FULL
review_mode="full"
track1_files_json="[]"
track2_files_json="[]"
prior_violations_json="[]"
untouched_violations_json="[]"

# Check all conditions for INCREMENTAL mode
can_incremental=true

# Condition 1: event action must be "synchronize"
if [[ "${GITHUB_EVENT_ACTION:-}" != "synchronize" ]]; then
  echo "Not synchronize event (action=${GITHUB_EVENT_ACTION:-unknown}) → FULL"
  can_incremental=false
fi

# Condition 2: BEFORE_SHA must not be all zeros
if [[ "$can_incremental" == "true" ]]; then
  if [[ "${BEFORE_SHA:-}" =~ ^0+$ ]] || [[ -z "${BEFORE_SHA:-}" ]]; then
    echo "BEFORE_SHA is zero/empty → FULL"
    can_incremental=false
  fi
fi

# Condition 3: BEFORE_SHA must be ancestor of AFTER_SHA (no force-push)
if [[ "$can_incremental" == "true" ]]; then
  if ! git merge-base --is-ancestor "$BEFORE_SHA" "$AFTER_SHA" 2>/dev/null; then
    echo "BEFORE_SHA is not ancestor of AFTER_SHA (force-push/rebase) → FULL"
    can_incremental=false
  fi
fi

# Condition 4: Prior artifact must exist and be valid JSON
if [[ "$can_incremental" == "true" ]]; then
  if [[ ! -f "$ARTIFACT_FILE" ]]; then
    echo "No prior artifact found → FULL"
    can_incremental=false
  elif ! jq -e '.active_violations' "$ARTIFACT_FILE" > /dev/null 2>&1; then
    echo "Prior artifact is invalid JSON → FULL"
    can_incremental=false
  fi
fi

# Condition 5: Prior artifact must have > 0 active violations
if [[ "$can_incremental" == "true" ]]; then
  local_count=$(jq '.active_violations | length' "$ARTIFACT_FILE")
  if [[ "$local_count" -eq 0 ]]; then
    echo "Prior artifact has 0 violations → FULL"
    can_incremental=false
  fi
fi

# --- Compute file lists ---

if [[ "$can_incremental" == "true" ]]; then
  review_mode="incremental"
  echo "All conditions met → INCREMENTAL"

  # Get files changed in this push only (BEFORE_SHA..AFTER_SHA)
  changed_files=$(git diff --name-only --diff-filter=ACMR "$BEFORE_SHA".."$AFTER_SHA" | filter_code_files || true)
  deleted_files=$(git diff --name-only --diff-filter=D "$BEFORE_SHA".."$AFTER_SHA" || true)

  # Load prior violations
  all_prior=$(jq -c '.active_violations' "$ARTIFACT_FILE")

  # Auto-resolve violations on deleted files
  if [[ -n "$deleted_files" ]]; then
    delete_filter=$(echo "$deleted_files" | jq -R -s 'split("\n") | map(select(length > 0))')
    all_prior=$(echo "$all_prior" | jq --argjson del "$delete_filter" '[.[] | select(.path as $p | ($del | index($p)) == null)]')
    echo "Auto-resolved violations on deleted files"
  fi

  # Partition: Track 1 = changed files that have prior violations
  # Track 2 = changed files without prior violations
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

  # Prior violations for Track 1 (only those on Track 1 files)
  prior_violations_json=$(echo "$all_prior" | jq --argjson t1 "$track1_files_json" '[.[] | select(.path as $p | ($t1 | index($p)) != null)]')

  # Untouched violations (on files NOT in this push)
  all_changed_json=$(echo "$changed_files" | jq -R -s 'split("\n") | map(select(length > 0))')
  untouched_violations_json=$(echo "$all_prior" | jq --argjson changed "$all_changed_json" '[.[] | select(.path as $p | ($changed | index($p)) == null)]')

else
  # FULL mode: get all changed files vs base branch
  changed_files=$(git diff --name-only --diff-filter=ACMR "origin/${BASE_REF:-main}...HEAD" | filter_code_files || true)
fi

code_files_json=$(echo "$changed_files" | jq -R -s 'split("\n") | map(select(length > 0))')

echo "::endgroup::"

# Output results
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
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/detect-review-mode.sh && bash -n scripts/detect-review-mode.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/detect-review-mode.sh
git commit -m "feat: add review mode detection (FULL vs INCREMENTAL)"
```

---

## Task 4: Cleanup Prior Reviews — `cleanup-prior-reviews.sh`

**Files:**
- Create: `scripts/cleanup-prior-reviews.sh`

- [ ] **Step 1: Create the cleanup script**

```bash
#!/usr/bin/env bash
# scripts/cleanup-prior-reviews.sh
#
# Cleans up prior bot reviews before posting a new one.
# - Dismisses prior REQUEST_CHANGES reviews from the bot
# - Deletes PENDING reviews left by failed runs
# - Minimizes (collapses) old inline comments via GraphQL
#
# Required env vars: PR_NUMBER, GITHUB_REPOSITORY, GH_TOKEN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

echo "::group::Cleanup Prior Reviews"

OWNER="${GITHUB_REPOSITORY%%/*}"
REPO="${GITHUB_REPOSITORY##*/}"

# Get all reviews on this PR
reviews=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --paginate 2>/dev/null || echo "[]")

# Get the bot's login (github-actions[bot] or the app name)
BOT_LOGIN="github-actions[bot]"

# Dismiss prior REQUEST_CHANGES reviews from the bot
echo "$reviews" | jq -r --arg bot "$BOT_LOGIN" \
  '.[] | select(.user.login == $bot and .state == "CHANGES_REQUESTED") | .id' | \
while IFS= read -r review_id; do
  [[ -z "$review_id" ]] && continue
  echo "Dismissing REQUEST_CHANGES review $review_id"
  gh api -X PUT "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$review_id/dismissals" \
    -f message="Superseded by new review run" \
    --silent 2>/dev/null || echo "Warning: failed to dismiss review $review_id"
done

# Delete PENDING reviews from the bot (left by crashed runs)
echo "$reviews" | jq -r --arg bot "$BOT_LOGIN" \
  '.[] | select(.user.login == $bot and .state == "PENDING") | .id' | \
while IFS= read -r review_id; do
  [[ -z "$review_id" ]] && continue
  echo "Deleting PENDING review $review_id"
  gh api -X DELETE "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$review_id" \
    --silent 2>/dev/null || echo "Warning: failed to delete review $review_id"
done

# Minimize old inline comments with our marker
# Get all review comments on the PR
comments=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments" --paginate 2>/dev/null || echo "[]")

# Find comments with our marker that aren't already minimized
comment_node_ids=$(echo "$comments" | jq -r --arg marker "$REVIEW_MARKER" \
  '.[] | select(.body | contains($marker)) | .node_id' 2>/dev/null || true)

while IFS= read -r node_id; do
  [[ -z "$node_id" ]] && continue
  echo "Minimizing comment $node_id"
  gh api graphql -f query="
    mutation {
      minimizeComment(input: {subjectId: \"$node_id\", classifier: OUTDATED}) {
        minimizedComment {
          isMinimized
        }
      }
    }
  " --silent 2>/dev/null || echo "Warning: failed to minimize comment $node_id"
done <<< "$comment_node_ids"

echo "Cleanup complete"
echo "::endgroup::"
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/cleanup-prior-reviews.sh && bash -n scripts/cleanup-prior-reviews.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/cleanup-prior-reviews.sh
git commit -m "feat: add cleanup script for prior bot reviews"
```

---

## Task 5: Pipeline Prompt — Full Mode

**Files:**
- Create: `prompts/pipeline-full.md`

- [ ] **Step 1: Create the full pipeline prompt template**

This is the prompt sent to Claude Code CLI (model: haiku) that orchestrates the 3-stage pipeline. It uses template variables that `run-review-pipeline.sh` will substitute: `{{CHANGED_FILES}}`, `{{SKILLS_DIR}}`, `{{HEAD_SHA}}`.

```markdown
You are a code review pipeline orchestrator. Execute the following 3-stage review pipeline and output ONLY the final JSON result.

## INPUT

Changed files (relative paths):
{{CHANGED_FILES}}

Skills directory: {{SKILLS_DIR}}
Commit SHA: {{HEAD_SHA}}

## STAGE 1 — CLASSIFICATION

Classify each file by its path into domains:
- **frontend**: files under `pages/`, `components/`, `app/`, `src/` with UI-related imports
- **backend**: files under `api/`, `server/`, `lib/`, `prisma/`, `db/`
- **ambiguous**: files that could be either — resolve by checking their imports

Rules:
1. Filter out non-code files. Only keep: .ts, .tsx, .js, .jsx, .prisma, .sql
2. Test files (*.test.*, *.spec.*) inherit the domain of their source file
3. For each file, trace one level of related files (direct imports and importers in the diff)

Output of this stage (internal, do not output): a mapping of domain → file list

## STAGE 2 — VALIDATION

For each domain that has files, spawn a sub-agent (use the Agent tool) with model `sonnet`.

If multiple domains have files, spawn agents in parallel.

Each sub-agent receives this instruction:

---
You are a code validation agent for the {{DOMAIN}} domain.

FILES TO VALIDATE:
{{DOMAIN_FILES}}

INSTRUCTIONS:
1. List all skill directories in {{SKILLS_DIR}}
2. For each skill, read SKILL.md to check if it applies to your domain/files
3. Read EVERY file listed above (use the Read tool, read the full file)
4. Validate each file against ALL applicable rules from ALL matching skills
5. Output ONLY a JSON array of violations (or empty array [] if none):

```json
[
  {
    "skill": "<skill-directory-name>",
    "rule": "<rule name from SKILL.md>",
    "scope": "<domain>",
    "path": "<relative file path>",
    "line": <line number>,
    "description": "<what violates the rule and why>",
    "suggestion": "<specific actionable fix>",
    "severity": "Critical | Recommended"
  }
]
```

Be thorough but precise. Only report REAL violations — if you're uncertain, do not report it.
---

Collect all sub-agent results. If ALL agents return empty arrays → skip to final output with verdict "pass".

## STAGE 3 — SYNTHESIS (only if violations found)

If any violations were found, spawn ONE sub-agent with model `opus`:

---
You are the synthesis agent. Your job is to filter false positives and format the final review.

POTENTIAL VIOLATIONS:
{{ALL_VIOLATIONS_JSON}}

INSTRUCTIONS:
1. For each violation, read the referenced file (full file, use Read tool)
2. Also read the skill file that produced the violation ({{SKILLS_DIR}}/<skill>/SKILL.md)
3. Classify each violation as TRUE VIOLATION or FALSE POSITIVE:
   - FALSE POSITIVE: the code actually follows the rule, or there's a valid exception
   - TRUE VIOLATION: the code genuinely breaks the rule
4. Priority for conflicting rules: Security > Data Integrity > Correctness > Maintainability
5. Format each confirmed violation's inline comment body as:

```
**<skill-name> > <rule>**

<explanation of WHY the code violates the rule>

**Suggestion:** <specific fix>

<!-- pr-code-review-validator -->
```

6. Output ONLY this JSON:

```json
{
  "confirmed_violations": [
    {
      "skill": "...",
      "rule": "...",
      "scope": "...",
      "path": "...",
      "line": 0,
      "body": "<formatted inline comment body>"
    }
  ],
  "false_positives": [
    {
      "skill": "...",
      "rule": "...",
      "path": "...",
      "line": 0,
      "reason": "<why this is not a violation>"
    }
  ]
}
```
---

## FINAL OUTPUT

After all stages complete, output ONLY this JSON (no other text):

```json
{
  "verdict": "pass | fail | skip",
  "summary": "<markdown summary — see format below>",
  "inline_comments": [
    { "path": "relative/path.ts", "line": 15, "side": "RIGHT", "body": "<formatted body>" }
  ],
  "stats": {
    "files_checked": 0,
    "files_changed": 0,
    "files_related": 0,
    "skills_applied": ["skill-name"],
    "violations_found": 0,
    "false_positives_filtered": 0
  }
}
```

**Verdict logic:**
- "pass" if 0 confirmed violations
- "fail" if >= 1 confirmed violation
- "skip" if no code files to review (all filtered out)

**Summary format for "pass":**
```
<!-- pr-code-review-validator -->
## REVIEW COMPLETE — PASSED (clean)

| Metric | Value |
|--------|-------|
| Files checked | N (X changed, Y related) |
| Skills applied | skill1, skill2 |
| Violations found | 0 |
| Status | **PASSED** |

---
*This review was generated by the PR Code Review Validator.*
```

**Summary format for "fail":**
```
<!-- pr-code-review-validator -->
## REVIEW COMPLETE — VIOLATIONS FOUND

| Metric | Value |
|--------|-------|
| Files checked | N (X changed, Y related) |
| Skills applied | skill1, skill2 |
| Violations found | C |
| False positives filtered | F |
| Status | **BLOCKED** |

### skill-name
- [ ] **Rule** — `path:line` — short description

---
*This review was generated by the PR Code Review Validator. All violations must be resolved before merging.*
```
```

- [ ] **Step 2: Commit**

```bash
git add prompts/pipeline-full.md
git commit -m "feat: add full pipeline prompt template (3-stage review)"
```

---

## Task 6: Pipeline Prompt — Incremental Track 1 (Verification)

**Files:**
- Create: `prompts/verification-track1.md`

- [ ] **Step 1: Create the Track 1 verification prompt**

```markdown
You are a violation verification agent. Your job is to check whether prior violations still exist after new code changes.

## PRIOR VIOLATIONS TO VERIFY

{{PRIOR_VIOLATIONS_JSON}}

## INSTRUCTIONS

For each violation listed above:
1. Read the file at the given path (use the Read tool, full file)
2. Check if the violation is STILL PRESENT or has been RESOLVED
3. If still present, provide the UPDATED line number (it may have shifted due to edits)
4. If the code was changed and no longer violates the rule, mark as "resolved"

## OUTPUT

Output ONLY this JSON (no other text):

```json
{
  "verified": [
    {
      "id": 0,
      "status": "still_present | resolved",
      "path": "relative/path.ts",
      "line": 15,
      "reason": "Brief explanation of why still present or how it was resolved"
    }
  ]
}
```

The `id` field corresponds to the index (0-based) in the PRIOR VIOLATIONS array above.
Every violation in the input MUST appear in the output. Do not skip any.
```

- [ ] **Step 2: Commit**

```bash
git add prompts/verification-track1.md
git commit -m "feat: add Track 1 verification prompt for incremental mode"
```

---

## Task 7: Pipeline Prompt — Incremental Track 2

**Files:**
- Create: `prompts/pipeline-incremental-track2.md`

- [ ] **Step 1: Create the Track 2 scoped pipeline prompt**

```markdown
You are a code review pipeline orchestrator. Execute the following 3-stage review pipeline on a SCOPED set of files (incremental review — only newly changed files without prior violations).

## INPUT

Files to validate (these are the ONLY files in scope):
{{TRACK2_FILES}}

Skills directory: {{SKILLS_DIR}}
Commit SHA: {{HEAD_SHA}}

## STAGE 1 — CLASSIFICATION

Classify each file by its path into domains:
- **frontend**: files under `pages/`, `components/`, `app/`, `src/` with UI-related imports
- **backend**: files under `api/`, `server/`, `lib/`, `prisma/`, `db/`
- **ambiguous**: resolve by checking imports

Rules:
1. Only process files listed above (do NOT expand scope)
2. Test files inherit domain from their source
3. Trace related files one level deep (only if also in the changed set)

## STAGE 2 — VALIDATION

For each domain with files, spawn a sub-agent (model `sonnet`). Parallel if multiple domains.

Each sub-agent instruction:

---
You are a code validation agent for the {{DOMAIN}} domain.

FILES TO VALIDATE:
{{DOMAIN_FILES}}

INSTRUCTIONS:
1. List all skill directories in {{SKILLS_DIR}}
2. For each skill, read SKILL.md to check if it applies to your domain/files
3. Read EVERY file listed above (full file)
4. Validate each file against ALL applicable rules
5. Output ONLY a JSON array of violations (or []):

```json
[
  {
    "skill": "<skill-directory-name>",
    "rule": "<rule name>",
    "scope": "<domain>",
    "path": "<relative path>",
    "line": <line number>,
    "description": "<what violates and why>",
    "suggestion": "<specific fix>",
    "severity": "Critical | Recommended"
  }
]
```
---

If all agents return [] → output pass verdict.

## STAGE 3 — SYNTHESIS (only if violations found)

Spawn one sub-agent (model `opus`):

---
You are the synthesis agent. Filter false positives and format the final review.

POTENTIAL VIOLATIONS:
{{ALL_VIOLATIONS_JSON}}

INSTRUCTIONS:
1. Read each referenced file and skill file
2. Classify as TRUE VIOLATION or FALSE POSITIVE
3. Priority: Security > Data Integrity > Correctness > Maintainability
4. Format confirmed violation bodies:

```
**<skill-name> > <rule>**

<explanation>

**Suggestion:** <fix>

<!-- pr-code-review-validator -->
```

5. Output JSON:

```json
{
  "confirmed_violations": [
    { "skill": "...", "rule": "...", "scope": "...", "path": "...", "line": 0, "body": "..." }
  ],
  "false_positives": [
    { "skill": "...", "rule": "...", "path": "...", "line": 0, "reason": "..." }
  ]
}
```
---

## FINAL OUTPUT

Output ONLY this JSON:

```json
{
  "verdict": "pass | fail | skip",
  "summary": "",
  "inline_comments": [
    { "path": "...", "line": 0, "side": "RIGHT", "body": "..." }
  ],
  "stats": {
    "files_checked": 0,
    "files_changed": 0,
    "files_related": 0,
    "skills_applied": [],
    "violations_found": 0,
    "false_positives_filtered": 0
  }
}
```

Note: summary will be built by the caller for incremental mode. Set it to empty string.
```

- [ ] **Step 2: Commit**

```bash
git add prompts/pipeline-incremental-track2.md
git commit -m "feat: add Track 2 scoped pipeline prompt for incremental mode"
```

---

## Task 8: Review Pipeline Script — `run-review-pipeline.sh`

**Files:**
- Create: `scripts/run-review-pipeline.sh`

- [ ] **Step 1: Create the main pipeline orchestration script**

```bash
#!/usr/bin/env bash
# scripts/run-review-pipeline.sh
#
# Orchestrates the AI review pipeline.
# In FULL mode: runs the 3-stage pipeline on all changed code files.
# In INCREMENTAL mode: runs Track 1 (verify) + Track 2 (validate new).
#
# Required env vars:
#   REVIEW_MODE (full|incremental)
#   CODE_FILES_JSON, TRACK1_FILES_JSON, TRACK2_FILES_JSON
#   PRIOR_VIOLATIONS_JSON, UNTOUCHED_VIOLATIONS_JSON
#   HEAD_SHA, PR_NUMBER
#
# Output: writes pipeline result to .review-artifacts/pipeline-output.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/json-extract.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILLS_DIR=".claude/skills"
OUTPUT_FILE="$ARTIFACT_DIR/pipeline-output.json"
PROMPTS_DIR="$REPO_ROOT/prompts"

mkdir -p "$ARTIFACT_DIR"

echo "::group::Review Pipeline ($REVIEW_MODE mode)"

# --- FULL MODE ---
run_full_pipeline() {
  local code_files="$1"
  local file_count
  file_count=$(echo "$code_files" | jq 'length')

  # Skip if no code files
  if [[ "$file_count" -eq 0 ]]; then
    cat > "$OUTPUT_FILE" <<'SKIPJSON'
{
  "verdict": "skip",
  "summary": "<!-- pr-code-review-validator -->\n## REVIEW SKIPPED — no code files changed\n\nOnly non-code files were modified in this PR. No skill-based review needed.\nStatus: **PASSED**\n\n---\n*This review was generated by the PR Code Review Validator.*",
  "inline_comments": [],
  "stats": {"files_checked":0,"files_changed":0,"files_related":0,"skills_applied":[],"violations_found":0,"false_positives_filtered":0}
}
SKIPJSON
    echo "No code files — skipping"
    return 0
  fi

  # Large PR warning
  if [[ "$file_count" -gt 50 ]]; then
    gh pr comment "$PR_NUMBER" --body "<!-- pr-code-review-validator -->
> **Warning:** This PR changes $file_count code files. Review may take longer than usual." 2>/dev/null || true
  fi

  # Build prompt from template
  local file_list
  file_list=$(echo "$code_files" | jq -r '.[]')
  local prompt
  prompt=$(cat "$PROMPTS_DIR/pipeline-full.md")
  prompt="${prompt//\{\{CHANGED_FILES\}\}/$file_list}"
  prompt="${prompt//\{\{SKILLS_DIR\}\}/$SKILLS_DIR}"
  prompt="${prompt//\{\{HEAD_SHA\}\}/$HEAD_SHA}"

  # Write prompt to temp file
  local prompt_file="$ARTIFACT_DIR/prompt-full.txt"
  echo "$prompt" > "$prompt_file"

  # Invoke Claude Code CLI
  local raw_output="$ARTIFACT_DIR/raw-output-full.json"
  echo "Invoking Claude Code CLI (model: $MODEL_CLASSIFY, timeout: ${TIMEOUT_FULL_PIPELINE}s)..."
  if ! timeout "$TIMEOUT_FULL_PIPELINE" claude --print --model "$MODEL_CLASSIFY" --output-format json < "$prompt_file" > "$raw_output" 2>/dev/null; then
    echo "ERROR: CLI invocation failed or timed out"
    return 1
  fi

  # Extract JSON from output
  if ! extract_json "$raw_output" "$OUTPUT_FILE"; then
    echo "ERROR: Failed to extract valid JSON from CLI output"
    return 1
  fi

  # Validate output has required fields
  if ! jq -e '.verdict' "$OUTPUT_FILE" > /dev/null 2>&1; then
    echo "ERROR: Output missing 'verdict' field"
    return 1
  fi

  echo "Pipeline complete: verdict=$(jq -r '.verdict' "$OUTPUT_FILE")"
}

# --- INCREMENTAL MODE ---
run_incremental_pipeline() {
  local track1_files="$1"
  local track2_files="$2"
  local prior_violations="$3"
  local untouched_violations="$4"

  local track1_count track2_count
  track1_count=$(echo "$track1_files" | jq 'length')
  track2_count=$(echo "$track2_files" | jq 'length')
  local total_code_files=$((track1_count + track2_count))

  # Short-circuit: no code files in this push
  if [[ "$total_code_files" -eq 0 ]]; then
    local untouched_count
    untouched_count=$(echo "$untouched_violations" | jq 'length')
    if [[ "$untouched_count" -gt 0 ]]; then
      # Fail with carried-forward violations
      build_incremental_output "fail" "[]" "$untouched_violations" "[]"
    else
      build_incremental_output "pass" "[]" "[]" "[]"
    fi
    return 0
  fi

  # --- Track 1: Verification ---
  local track1_result="[]"
  if [[ "$track1_count" -gt 0 ]]; then
    echo "Track 1: Verifying $track1_count files with prior violations..."
    local prompt
    prompt=$(cat "$PROMPTS_DIR/verification-track1.md")
    prompt="${prompt//\{\{PRIOR_VIOLATIONS_JSON\}\}/$prior_violations}"

    local prompt_file="$ARTIFACT_DIR/prompt-track1.txt"
    echo "$prompt" > "$prompt_file"

    local raw_output="$ARTIFACT_DIR/raw-output-track1.json"
    if timeout "$TIMEOUT_TRACK1_VERIFY" claude --print --model "$MODEL_VALIDATE" --output-format json < "$prompt_file" > "$raw_output" 2>/dev/null; then
      local extracted="$ARTIFACT_DIR/extracted-track1.json"
      if extract_json "$raw_output" "$extracted" && jq -e '.verified' "$extracted" > /dev/null 2>&1; then
        track1_result=$(jq -c '.verified' "$extracted")
        echo "Track 1 complete: $(echo "$track1_result" | jq '[.[] | select(.status == "still_present")] | length') still present"
      else
        echo "WARNING: Track 1 extraction failed — assuming all still_present"
        track1_result=$(echo "$prior_violations" | jq -c '[to_entries[] | {id: .key, status: "still_present", path: .value.path, line: .value.line, reason: "Verification failed — assumed still present"}]')
      fi
    else
      echo "WARNING: Track 1 timed out — assuming all still_present"
      track1_result=$(echo "$prior_violations" | jq -c '[to_entries[] | {id: .key, status: "still_present", path: .value.path, line: .value.line, reason: "Verification timed out — assumed still present"}]')
    fi
  fi

  # --- Track 2: Full Validation of new files ---
  local track2_violations="[]"
  if [[ "$track2_count" -gt 0 ]]; then
    echo "Track 2: Validating $track2_count new files..."
    local file_list
    file_list=$(echo "$track2_files" | jq -r '.[]')
    local prompt
    prompt=$(cat "$PROMPTS_DIR/pipeline-incremental-track2.md")
    prompt="${prompt//\{\{TRACK2_FILES\}\}/$file_list}"
    prompt="${prompt//\{\{SKILLS_DIR\}\}/$SKILLS_DIR}"
    prompt="${prompt//\{\{HEAD_SHA\}\}/$HEAD_SHA}"

    local prompt_file="$ARTIFACT_DIR/prompt-track2.txt"
    echo "$prompt" > "$prompt_file"

    local raw_output="$ARTIFACT_DIR/raw-output-track2.json"
    if timeout "$TIMEOUT_FULL_PIPELINE" claude --print --model "$MODEL_CLASSIFY" --output-format json < "$prompt_file" > "$raw_output" 2>/dev/null; then
      local extracted="$ARTIFACT_DIR/extracted-track2.json"
      if extract_json "$raw_output" "$extracted" && jq -e '.verdict' "$extracted" > /dev/null 2>&1; then
        track2_violations=$(jq -c '.inline_comments // []' "$extracted")
        echo "Track 2 complete: $(echo "$track2_violations" | jq 'length') violations"
      else
        echo "ERROR: Track 2 extraction failed"
        return 1
      fi
    else
      echo "ERROR: Track 2 timed out"
      return 1
    fi
  fi

  # --- Merge tracks ---
  build_incremental_output "" "$track1_result" "$untouched_violations" "$track2_violations"
}

# Builds the final merged output for incremental mode
build_incremental_output() {
  local forced_verdict="$1"
  local track1_result="$2"
  local untouched_violations="$3"
  local track2_inline="$4"

  # Track 1: still_present violations (with updated lines)
  local prior_violations_arr
  prior_violations_arr=$(echo "${PRIOR_VIOLATIONS_JSON}" | jq -c '.')
  local still_present_violations
  still_present_violations=$(echo "$track1_result" | jq -c --argjson prior "$prior_violations_arr" \
    '[.[] | select(.status == "still_present") | . as $v | $prior[$v.id] | .line = $v.line]' 2>/dev/null || echo "[]")

  # Combine all active violations
  local all_active
  all_active=$(jq -n --argjson untouched "$untouched_violations" \
    --argjson still "$still_present_violations" \
    '$untouched + $still')

  local total_violations
  total_violations=$(echo "$all_active" | jq 'length')
  local track2_count
  track2_count=$(echo "$track2_inline" | jq 'length')
  total_violations=$((total_violations + track2_count))

  # Determine verdict
  local verdict
  if [[ -n "$forced_verdict" ]]; then
    verdict="$forced_verdict"
  elif [[ "$total_violations" -eq 0 ]]; then
    verdict="pass"
  else
    verdict="fail"
  fi

  # Build inline comments from all active violations
  local inline_comments
  inline_comments=$(echo "$all_active" | jq -c '[.[] | {path: .path, line: .line, side: "RIGHT", body: .body}]')
  # Append Track 2 inline comments
  inline_comments=$(jq -n --argjson existing "$inline_comments" --argjson new "$track2_inline" '$existing + $new')

  # Build summary
  local summary
  if [[ "$verdict" == "pass" ]]; then
    summary="<!-- pr-code-review-validator -->\n## REVIEW COMPLETE — PASSED (clean)\n\n| Metric | Value |\n|--------|-------|\n| Review mode | Incremental |\n| Violations found | 0 |\n| Status | **PASSED** |\n\n---\n*This review was generated by the PR Code Review Validator.*"
  else
    summary="<!-- pr-code-review-validator -->\n## REVIEW COMPLETE — VIOLATIONS FOUND (incremental)\n\n| Metric | Value |\n|--------|-------|\n| Review mode | Incremental |\n| Active violations | $total_violations |\n| Status | **BLOCKED** |\n\n---\n*This review was generated by the PR Code Review Validator. All violations must be resolved before merging.*"
  fi

  jq -n \
    --arg verdict "$verdict" \
    --arg summary "$summary" \
    --argjson inline "$inline_comments" \
    --argjson violations_found "$total_violations" \
    '{
      verdict: $verdict,
      summary: $summary,
      inline_comments: $inline,
      stats: {
        files_checked: 0,
        files_changed: 0,
        files_related: 0,
        skills_applied: [],
        violations_found: $violations_found,
        false_positives_filtered: 0
      }
    }' > "$OUTPUT_FILE"

  echo "Incremental merge complete: verdict=$verdict, violations=$total_violations"
}

# --- MAIN ---
if [[ "$REVIEW_MODE" == "full" ]]; then
  run_full_pipeline "$CODE_FILES_JSON"
elif [[ "$REVIEW_MODE" == "incremental" ]]; then
  run_incremental_pipeline "$TRACK1_FILES_JSON" "$TRACK2_FILES_JSON" "$PRIOR_VIOLATIONS_JSON" "$UNTOUCHED_VIOLATIONS_JSON"
else
  echo "ERROR: Unknown review mode: $REVIEW_MODE"
  exit 1
fi

echo "::endgroup::"
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/run-review-pipeline.sh && bash -n scripts/run-review-pipeline.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/run-review-pipeline.sh
git commit -m "feat: add review pipeline orchestration script (full + incremental)"
```

---

## Task 9: Post Review Script — `post-review.sh`

**Files:**
- Create: `scripts/post-review.sh`

- [ ] **Step 1: Create the post-review script**

```bash
#!/usr/bin/env bash
# scripts/post-review.sh
#
# Posts the review to GitHub and writes the violations artifact.
# Handles: pipeline crash, JSON parsing, path filtering, bundled review posting,
# fallback to body-only, artifact writing.
#
# Required env vars: PR_NUMBER, HEAD_SHA, GITHUB_REPOSITORY, PUSH_COUNT
# Input: .review-artifacts/pipeline-output.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

echo "::group::Post Review"

OWNER="${GITHUB_REPOSITORY%%/*}"
REPO="${GITHUB_REPOSITORY##*/}"
OUTPUT_FILE="$ARTIFACT_DIR/pipeline-output.json"

# --- Handle pipeline crash (no output or invalid JSON) ---
if [[ ! -f "$OUTPUT_FILE" ]]; then
  echo "ERROR: No pipeline output — posting fail-closed review"
  gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
    -f event="REQUEST_CHANGES" \
    -f body="<!-- pr-code-review-validator -->
## REVIEW ERROR — Pipeline Crash

The code review pipeline failed to produce output. This PR is blocked until the pipeline runs successfully.

**Error:** No output file generated. Check workflow logs for details.

---
*This review was generated by the PR Code Review Validator.*" \
    --silent
  exit 1
fi

if ! jq -e '.verdict' "$OUTPUT_FILE" > /dev/null 2>&1; then
  echo "ERROR: Invalid pipeline output — posting fail-closed review"
  gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
    -f event="REQUEST_CHANGES" \
    -f body="<!-- pr-code-review-validator -->
## REVIEW ERROR — Invalid Output

The code review pipeline produced output that could not be parsed. This PR is blocked until the pipeline runs successfully.

**Error:** Output missing 'verdict' field or invalid JSON.

---
*This review was generated by the PR Code Review Validator.*" \
    --silent
  exit 1
fi

# --- Read pipeline output ---
verdict=$(jq -r '.verdict' "$OUTPUT_FILE")
summary=$(jq -r '.summary' "$OUTPUT_FILE")
inline_comments=$(jq -c '.inline_comments // []' "$OUTPUT_FILE")
inline_count=$(echo "$inline_comments" | jq 'length')

echo "Verdict: $verdict, Inline comments: $inline_count"

# --- Filter inline comments to only paths in the PR diff ---
pr_diff_files=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/files" --paginate | jq -r '.[].filename')
if [[ -n "$pr_diff_files" ]]; then
  pr_files_json=$(echo "$pr_diff_files" | jq -R -s 'split("\n") | map(select(length > 0))')
  inline_comments=$(echo "$inline_comments" | jq --argjson valid "$pr_files_json" '[.[] | select(.path as $p | ($valid | index($p)) != null)]')
  inline_count=$(echo "$inline_comments" | jq 'length')
  echo "After path filter: $inline_count inline comments"
fi

# --- Determine review event ---
review_event="COMMENT"
if [[ "$verdict" == "fail" ]]; then
  review_event="REQUEST_CHANGES"
fi

# --- Post bundled review ---
post_succeeded=false

if [[ "$inline_count" -gt 0 ]]; then
  # Build the review payload with inline comments
  review_payload=$(jq -n \
    --arg event "$review_event" \
    --arg body "$summary" \
    --arg sha "$HEAD_SHA" \
    --argjson comments "$inline_comments" \
    '{
      event: $event,
      body: $body,
      commit_id: $sha,
      comments: $comments
    }')

  echo "Posting review with $inline_count inline comments..."
  if echo "$review_payload" | gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
    --input - --silent 2>/dev/null; then
    post_succeeded=true
    echo "Review posted successfully with inline comments"
  else
    echo "WARNING: Review with comments failed (likely path/line mismatch)"
    # Check if a partial review was created
    latest_reviews=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --jq '.[0]' 2>/dev/null || echo "{}")
    latest_state=$(echo "$latest_reviews" | jq -r '.state // ""')
    if [[ "$latest_state" == "PENDING" ]]; then
      # Delete the partial review
      latest_id=$(echo "$latest_reviews" | jq -r '.id')
      gh api -X DELETE "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$latest_id" --silent 2>/dev/null || true
    fi

    # Fallback: post body-only review with violations listed in summary
    echo "Falling back to body-only review..."
    fallback_body="$summary"
    gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
      -f event="$review_event" \
      -f body="$fallback_body" \
      -f commit_id="$HEAD_SHA" \
      --silent
    post_succeeded=true
    echo "Body-only review posted (fallback)"
  fi
else
  # No inline comments — post body-only review
  gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" \
    -f event="$review_event" \
    -f body="$summary" \
    -f commit_id="$HEAD_SHA" \
    --silent
  post_succeeded=true
  echo "Body-only review posted"
fi

# --- On pass/skip: dismiss any lingering REQUEST_CHANGES ---
if [[ "$verdict" == "pass" || "$verdict" == "skip" ]]; then
  echo "Dismissing any lingering REQUEST_CHANGES reviews..."
  BOT_LOGIN="github-actions[bot]"
  reviews=$(gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews" --paginate 2>/dev/null || echo "[]")
  echo "$reviews" | jq -r --arg bot "$BOT_LOGIN" \
    '.[] | select(.user.login == $bot and .state == "CHANGES_REQUESTED") | .id' | \
  while IFS= read -r review_id; do
    [[ -z "$review_id" ]] && continue
    gh api -X PUT "repos/$OWNER/$REPO/pulls/$PR_NUMBER/reviews/$review_id/dismissals" \
      -f message="Review passed — violations resolved" \
      --silent 2>/dev/null || true
  done
fi

# --- Write violations artifact ---
echo "Writing violations artifact..."
# Extract violation metadata from inline comment bodies
active_violations=$(echo "$inline_comments" | jq --arg push "${PUSH_COUNT:-1}" '[.[] | {
  path: .path,
  line: .line,
  skill: ((.body | capture("\\*\\*(?<s>[^>]+) >") | .s) // "unknown"),
  rule: ((.body | capture("> (?<r>[^*]+)\\*\\*") | .r) // "unknown"),
  description: "",
  suggestion: "",
  found_in_push: ($push | tonumber),
  body: .body
}]')

jq -n \
  --argjson pr "$PR_NUMBER" \
  --arg sha "$HEAD_SHA" \
  --argjson push "${PUSH_COUNT:-1}" \
  --argjson violations "$active_violations" \
  '{
    pr_number: $pr,
    last_push_sha: $sha,
    push_count: $push,
    active_violations: $violations
  }' > "$ARTIFACT_FILE"

echo "Artifact written: $(jq '.active_violations | length' "$ARTIFACT_FILE") violations"
echo "::endgroup::"

# --- Exit code ---
if [[ "$verdict" == "fail" ]]; then
  echo "::error::Code review found violations — PR blocked"
  exit 1
else
  echo "Review complete — $verdict"
  exit 0
fi
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/post-review.sh && bash -n scripts/post-review.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/post-review.sh
git commit -m "feat: add post-review script (GitHub API posting + artifact)"
```

---

## Task 10: GitHub Actions Workflow

**Files:**
- Create: `.github/workflows/pr-code-review-validator.yml`

- [ ] **Step 1: Create the workflow file**

```yaml
name: PR Code Review Validator

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, labeled]

concurrency:
  group: pr-review-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  actions: read

jobs:
  review:
    name: Code Review
    runs-on: ubuntu-latest
    timeout-minutes: 10
    if: github.event.pull_request.draft == false

    env:
      ANTHROPIC_BEDROCK_BASE_URL: ${{ secrets.BEDROCK_BASE_URL }}
      ANTHROPIC_CUSTOM_HEADERS: "x-portkey-api-key:${{ secrets.PORTKEY_API_KEY }}\nx-portkey-provider:@aws-bedrock-use2"
      CLAUDE_CODE_USE_BEDROCK: "1"
      CLAUDE_CODE_SKIP_BEDROCK_AUTH: "1"
      PR_NUMBER: ${{ github.event.pull_request.number }}
      HEAD_SHA: ${{ github.event.pull_request.head.sha }}
      BASE_REF: ${{ github.event.pull_request.base.ref }}
      BEFORE_SHA: ${{ github.event.before }}
      AFTER_SHA: ${{ github.event.after }}
      GITHUB_EVENT_ACTION: ${{ github.event.action }}
      GH_TOKEN: ${{ github.token }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "20"

      - name: Install Claude Code CLI
        run: npm install -g @anthropic-ai/claude-code

      - name: Install jq
        run: sudo apt-get install -y jq

      - name: Download prior artifact
        id: download-artifact
        uses: actions/download-artifact@v4
        with:
          name: pr-${{ github.event.pull_request.number }}-violations
          path: .review-artifacts/
        continue-on-error: true

      - name: Detect review mode
        id: detect-mode
        run: bash scripts/detect-review-mode.sh
        env:
          PUSH_COUNT: ${{ steps.download-artifact.outcome == 'success' && '0' || '1' }}

      - name: Compute push count
        id: push-count
        run: |
          if [[ -f ".review-artifacts/violations.json" ]]; then
            count=$(jq '.push_count // 0' .review-artifacts/violations.json)
            echo "count=$((count + 1))" >> "$GITHUB_OUTPUT"
          else
            echo "count=1" >> "$GITHUB_OUTPUT"
          fi

      - name: Cleanup prior reviews
        run: bash scripts/cleanup-prior-reviews.sh

      - name: Run review pipeline
        id: pipeline
        run: bash scripts/run-review-pipeline.sh
        env:
          REVIEW_MODE: ${{ steps.detect-mode.outputs.review_mode }}
          CODE_FILES_JSON: ${{ steps.detect-mode.outputs.code_files_json }}
          TRACK1_FILES_JSON: ${{ steps.detect-mode.outputs.track1_files_json }}
          TRACK2_FILES_JSON: ${{ steps.detect-mode.outputs.track2_files_json }}
          PRIOR_VIOLATIONS_JSON: ${{ steps.detect-mode.outputs.prior_violations_json }}
          UNTOUCHED_VIOLATIONS_JSON: ${{ steps.detect-mode.outputs.untouched_violations_json }}
          PUSH_COUNT: ${{ steps.push-count.outputs.count }}

      - name: Post review
        if: always()
        run: bash scripts/post-review.sh
        env:
          PUSH_COUNT: ${{ steps.push-count.outputs.count }}

      - name: Upload violations artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: pr-${{ github.event.pull_request.number }}-violations
          path: .review-artifacts/violations.json
          retention-days: 90
          overwrite: true
          if-no-files-found: ignore
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/pr-code-review-validator.yml'))" 2>&1 || echo "Install PyYAML: pip install pyyaml"`

If PyYAML isn't available: `npx yaml-lint .github/workflows/pr-code-review-validator.yml` or just confirm the file was written correctly.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/pr-code-review-validator.yml
git commit -m "feat: add GitHub Actions workflow for PR code review"
```

---

## Task 11: Skills Directory Scaffold

**Files:**
- Create: `.claude/skills/.gitkeep`

- [ ] **Step 1: Create the skills directory placeholder**

```bash
mkdir -p .claude/skills
touch .claude/skills/.gitkeep
```

- [ ] **Step 2: Commit**

```bash
git add .claude/skills/.gitkeep
git commit -m "feat: add empty skills directory for review sub-agents"
```

---

## Task 12: Integration Test — Dry Run Script

**Files:**
- Create: `scripts/test-pipeline-local.sh`

- [ ] **Step 1: Create a local test script for verifying the pipeline end-to-end without GitHub Actions**

```bash
#!/usr/bin/env bash
# scripts/test-pipeline-local.sh
#
# Local dry-run of the review pipeline for testing.
# Simulates what GitHub Actions does, using local git state.
#
# Usage: ./scripts/test-pipeline-local.sh [base-branch]
#   base-branch: branch to diff against (default: main)
#
# Prerequisites:
#   - Claude Code CLI installed and configured
#   - jq installed
#   - At least one skill in .claude/skills/

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

# Check prerequisites
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

# Simulate FULL mode
export REVIEW_MODE="full"
export HEAD_SHA
export PR_NUMBER
export BASE_REF="$BASE_BRANCH"

# Get changed files
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

# Run pipeline
echo "=== Running Pipeline ==="
mkdir -p "$ARTIFACT_DIR"
bash "$SCRIPT_DIR/run-review-pipeline.sh"

# Show results
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
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x scripts/test-pipeline-local.sh && bash -n scripts/test-pipeline-local.sh`
Expected: No output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/test-pipeline-local.sh
git commit -m "feat: add local test script for pipeline dry-runs"
```

---

## Task 13: Final Verification

- [ ] **Step 1: Verify all files are committed and no leftover changes**

Run: `git status`
Expected: clean working tree (nothing to commit)

- [ ] **Step 2: Verify file structure matches the plan**

Run: `find .github scripts prompts .claude/skills -type f | sort`
Expected:
```
.claude/skills/.gitkeep
.github/workflows/pr-code-review-validator.yml
prompts/pipeline-full.md
prompts/pipeline-incremental-track2.md
prompts/verification-track1.md
scripts/cleanup-prior-reviews.sh
scripts/detect-review-mode.sh
scripts/lib/common.sh
scripts/lib/json-extract.sh
scripts/post-review.sh
scripts/run-review-pipeline.sh
scripts/test-pipeline-local.sh
```

- [ ] **Step 3: Verify all scripts are executable**

Run: `ls -la scripts/*.sh scripts/lib/*.sh`
Expected: All show `-rwxr-xr-x` permissions

- [ ] **Step 4: Run syntax check on all scripts**

Run: `for f in scripts/*.sh scripts/lib/*.sh; do echo -n "$f: "; bash -n "$f" && echo "OK" || echo "FAIL"; done`
Expected: All OK

# GitHub Code Review Integration — Spec

## ROLE

You are a GitHub Code Review Orchestrator — an autonomous CI/CD pipeline that reviews pull requests for code quality violations using AI agents.

You operate as:
- **Orchestrator + Synthesizer (Opus):** Controls the review lifecycle, decides review mode, dispatches stages, merges results, filters false positives, and produces the final GitHub PR review.
- **Classifier (Haiku):** Classifies changed files by domain and routes them to appropriate validation sub-agents.
- **Validators (Sonnet sub-agents):** Pluggable agents that validate files against domain-specific rules. Each sub-agent owns a skill and receives only relevant files.

You do NOT enforce any specific coding rules yourself — validation is fully delegated to pluggable sub-agents. This makes the system extensible: adding a new skill means adding a new validation sub-agent with zero changes to the orchestrator, classifier, or synthesizer.

---

## CONTEXT

### Infrastructure

- **Runtime:** GitHub Actions (ubuntu-latest, timeout 10 minutes)
- **AI Gateway:** Portkey → AWS Bedrock (Claude models: Haiku, Sonnet, Opus)
- **CLI:** Claude Code CLI (`@anthropic-ai/claude-code`), invoked in print mode
- **GitHub API:** via `gh` CLI for posting reviews, managing comments, artifacts

### Connection to Claude (via Portkey + Bedrock)

**Required GitHub Secrets (set as Repository Secrets, NOT Environment Secrets):**
- `BEDROCK_BASE_URL` — Portkey gateway URL (NOT a raw Bedrock endpoint). This is the URL Portkey provides for routing requests to Bedrock. Must be copied verbatim from a working deployment.
- `PORTKEY_API_KEY` — API key from Portkey dashboard. A 403 "Forbidden" error means this key is invalid or the base URL is wrong.
- `GITHUB_TOKEN` — Auto-provided by GitHub Actions (repo scope)

**Deployment note:** When setting up a new repository, copy both `BEDROCK_BASE_URL` and `PORTKEY_API_KEY` directly from the working reference repository's secrets. Do NOT retype manually — a single character difference causes silent auth failures that manifest as 3-minute timeouts.

**Environment variables set in the workflow:**

```
ANTHROPIC_BEDROCK_BASE_URL: "${{ secrets.BEDROCK_BASE_URL }}"
ANTHROPIC_CUSTOM_HEADERS: "x-portkey-api-key:${{ secrets.PORTKEY_API_KEY }}\nx-portkey-provider:@aws-bedrock-use2"
CLAUDE_CODE_USE_BEDROCK: "1"
CLAUDE_CODE_SKIP_BEDROCK_AUTH: "1"
```

**CLI invocation pattern:**

```bash
claude --print --model <model> --output-format json < prompt-file.txt > output.json
```

**Models used (short names only — Portkey resolves to Bedrock model IDs):**
- `haiku` → Classification stage (Stage 1) + Track 2 full validation
- `sonnet` → Validation sub-agents (Stage 2) + Track 1 verification
- `opus` → Synthesis stage (Stage 3, only when violations found)

**Important:** Always use short model names (`haiku`, `sonnet`, `opus`) in CLI invocations. The Portkey gateway resolves these to the appropriate Bedrock model ARNs. Using full model IDs (e.g., `claude-haiku-4-5-20251001`, `us.anthropic.claude-haiku-4-5-20251001-v1:0`) will cause 400 errors from Portkey.

### Trigger

GitHub Actions workflow on `pull_request` events:
- `opened` — new PR created
- `synchronize` — new commits pushed to existing PR
- `reopened` — closed PR reopened
- `ready_for_review` — draft PR marked as ready
- `labeled` — when `full-review` label is applied

Concurrency: one review per PR (`cancel-in-progress: true`).
Skip: draft PRs are ignored.

### Review Modes

**FULL** — validate all changed files from scratch.
Triggers: initial PR, force-push, `full-review` label, no prior artifact, prior artifact with zero violations, BEFORE_SHA is all zeros.

**INCREMENTAL** — two-track review for subsequent commits.
Triggers: synchronize event + valid prior violations artifact exists + BEFORE_SHA is ancestor of AFTER_SHA (no force-push).
- **Track 1:** Re-validate prior violations on files touched in this push. Status per violation: `still_present` | `resolved` | `auto-resolved` (file deleted).
- **Track 2:** Full validation of newly changed files and files without prior violations.
- **Result:** Merged artifact = untouched violations + Track 1 still_present + Track 2 new.

### Artifacts

Violation state is persisted between runs as GitHub Actions artifacts:
- Name: `pr-<number>-violations`
- Path: `.review-artifacts/violations.json`
- Retention: 90 days
- Schema: `{ pr_number, last_push_sha, push_count, active_violations[] }`

### Output (posted to GitHub)

- Bundled PR review (single notification) with:
  - Summary comment (pass/fail status, metrics table, violation checklist)
  - Inline comments on specific lines (one per violation)
- Review event: `REQUEST_CHANGES` (fail) | `COMMENT` (pass/skip)
- Policy: Fail-closed — pipeline crash or invalid output → `REQUEST_CHANGES`

### Cleanup (before posting new review)

- Dismiss prior `REQUEST_CHANGES` reviews from bot
- Delete `PENDING` reviews left by failed runs
- Minimize (collapse) old inline comments via GraphQL `minimizeComment` mutation

### Extension Model

Validation sub-agents are the primary extension point. Each sub-agent:
- Declares which file classifications it handles (e.g., "frontend", "backend")
- Receives classified files from the Haiku stage
- Returns a JSON array of structured violation findings
- Is independent of other sub-agents (can run in parallel)

Adding a new skill = adding a new validation sub-agent with its own prompt. No changes to orchestrator, classifier, or synthesizer required.

---

## TASK

Implement a GitHub-integrated code review system that automatically reviews pull requests using a multi-agent AI pipeline. The system must:

### 1. Workflow Setup

a. Create a GitHub Actions workflow (`.github/workflows/pr-code-review-validator.yml`) that triggers on `pull_request` events (`opened`, `synchronize`, `reopened`, `ready_for_review`, `labeled`).
b. Configure concurrency (one review per PR, cancel-in-progress).
c. Skip draft PRs.
d. Set permissions: `contents:read`, `pull-requests:write`, `actions:read`.

### 2. Claude Code CLI Integration

a. Install Claude Code CLI: `npm install -g @anthropic-ai/claude-code`
b. Configure environment variables for Portkey → Bedrock connection:
   - `ANTHROPIC_BEDROCK_BASE_URL` = `secrets.BEDROCK_BASE_URL`
   - `ANTHROPIC_CUSTOM_HEADERS` = `"x-portkey-api-key:<key>\nx-portkey-provider:@aws-bedrock-use2"`
   - `CLAUDE_CODE_USE_BEDROCK` = `"1"`
   - `CLAUDE_CODE_SKIP_BEDROCK_AUTH` = `"1"`
c. Invoke CLI with: `claude --print --model <model> --output-format json < prompt.txt > output.json`
   - Models MUST use short names: `haiku`, `sonnet`, `opus`. Do NOT use full Bedrock model IDs (e.g., `us.anthropic.claude-haiku-4-5-20251001-v1:0`) — Portkey resolves short names internally. Full IDs cause 400 "invalid model identifier" errors.
   - The `--print` flag produces non-interactive output but does NOT disable tool use — the model can still use Bash, Read, Agent tools and execute multiple turns.
d. Parse output using multi-strategy JSON extraction. The CLI returns a JSON envelope: `{"type":"result","result":"<model response string>"}`. The `.result` field contains the model's text response which MAY be wrapped in markdown code fences (`` ```json ... ``` ``). Extraction strategies (applied in order):
   1. Direct JSON — the file itself is valid JSON with a `verdict` field
   2. CLI envelope — extract `.result` field, strip markdown fences if present, parse as JSON
   3. Content blocks array — extract from `.content[0].text`
   4. Embedded JSON in text — find first `{` or `[` that parses as valid JSON
   
   **Critical:** The model may wrap its JSON response in `` ```json `` fences despite being instructed not to. The extraction layer MUST handle this defensively by stripping fences before parsing.

### 3. Review Mode Detection (`detect-review-mode.sh`)

a. Default to FULL mode.
b. Switch to INCREMENTAL only when ALL conditions are met:
   - Event action is `synchronize`
   - BEFORE_SHA is not all zeros
   - BEFORE_SHA is ancestor of AFTER_SHA (no force-push/rebase)
   - Prior violations artifact exists and is valid JSON
   - Prior artifact has > 0 active violations
c. On INCREMENTAL: compute diff between `BEFORE_SHA..AFTER_SHA`, filter to code files, partition into Track 1 (files with prior violations) and Track 2 (files without prior violations). Auto-resolve violations on deleted files.
d. Output: `review_mode` (full|incremental) + `prior-findings.json` with track data.

### 4. Cleanup (`cleanup-prior-reviews.sh`)

Before posting any new review, clean stale state:
- Dismiss prior `REQUEST_CHANGES` reviews from the bot
- Delete `PENDING` reviews left by failed runs
- Minimize (collapse) old inline comments via GraphQL `minimizeComment` mutation

### 5. Review Pipeline (`run-review-pipeline.sh`)

#### FULL MODE

a. Large PR warning: if >50 code files, post a warning comment.
b. Build pipeline prompt and invoke Claude Code CLI with model `haiku`.
c. The prompt instructs a 3-stage pipeline:

**Stage 1 — Classification (executed by Haiku directly):**
- Get changed files via `git diff`
- Filter non-code files (configs, images, docs, directories)
- Keep only: `.ts`, `.tsx`, `.js`, `.jsx`, `.prisma`, `.sql`
- Classify files by path into domains (frontend, backend, ambiguous)
- Resolve ambiguous files by checking importers
- Classify test files by inheriting from their source
- Trace related files one level deep (imports/importers)

**Stage 2 — Validation (Haiku spawns Sonnet sub-agents via Agent tool):**
- One sub-agent per domain (e.g., frontend agent, backend agent)
- If multiple domains, spawn agents in parallel
- Each sub-agent reads skill files fresh, reads all source files, validates against all rules, outputs JSON array of violations
- If zero violations across all agents → output pass verdict and STOP

**Stage 3 — Synthesis (Haiku spawns Opus sub-agent, only if violations found):**
- Receives all potential violations
- Reads skill files and all referenced source files (full context)
- Classifies each as TRUE VIOLATION or FALSE POSITIVE
- Resolves conflicting rules (priority: Security > Data Integrity > Correctness > Maintainability)
- Formats inline comment bodies with skill/rule headers
- Outputs: `confirmed_violations[]` + `false_positives[]`

Final output: JSON with verdict, summary, `inline_comments[]`, `stats{}`

#### INCREMENTAL MODE

a. Short-circuit if no code files in this push:
   - If untouched violations exist → fail with carried-forward violations
   - If no violations at all → pass
b. **Track 1 (Verification):**
   - Build verification prompt with prior violations
   - Invoke CLI with model `sonnet`
   - For each prior violation: determine `still_present` (with updated line) or `resolved`
   - Fail-safe: if verification fails, assume all still_present
c. **Track 2 (Full Validation):**
   - Scope the pipeline prompt to only Track 2 files
   - Invoke CLI with model `haiku` (same 3-stage pipeline, scoped)
d. **Merge tracks:**
   - Combine: untouched + Track 1 still_present + Track 2 new violations
   - Determine verdict: pass (0 active) or fail (>0 active)
   - Build inline comments and summary

### 6. Post Review (`post-review.sh`)

a. Handle pipeline crash (no output): post `REQUEST_CHANGES` with error message.
b. Validate output is parseable JSON.
c. Filter inline comments to only paths present in the PR diff.
d. Post bundled GitHub review:
   - If inline comments exist: POST reviews API with comments array
   - If posting with comments fails (path/line mismatch): detect if review was partially created, then fallback to body-only review with violations in summary
   - If no inline comments: post body-only review
e. On pass/skip verdict: dismiss any lingering `REQUEST_CHANGES` reviews.
f. Write violations artifact for next run.
g. Exit with code 0 (pass/skip) or 1 (fail) to signal workflow status.

### 7. Artifact Management

a. Download prior artifact at workflow start (`continue-on-error: true`).
b. Build artifact from pipeline output (extract violation metadata from inline comment bodies: skill, rule, description, suggestion, found_in_push).
c. Upload artifact after posting review (`overwrite: true`, retention: 90 days).

---

## CRITERIA

### 1. Fail-Closed Policy
If the pipeline crashes, produces no output, or produces invalid JSON, the system MUST post a `REQUEST_CHANGES` review blocking the merge. Never silently pass. Every failure mode must result in a visible review.

### 2. Single Notification
All inline comments and the summary MUST be posted as a single bundled review (one GitHub notification to the PR author), not as individual comments.

### 3. Idempotent Cleanup
Before posting a new review, all prior bot reviews must be dismissed/minimized. Re-running the workflow on the same commit must produce a clean state.

### 4. Extensibility
Adding a new validation skill MUST NOT require changes to the orchestrator, classifier prompt structure, synthesizer, or any shell script. A new sub-agent plugs in at Stage 2 only, defined by:
- (a) File classification rules (which paths it handles)
- (b) Skill files it reads
- (c) Rules it validates against
- (d) JSON output schema (same structure as existing agents)

### 5. Incremental Efficiency
On subsequent pushes, the system MUST only re-validate files that changed and carry forward untouched violations without re-running the full pipeline. Force-push or rebase MUST trigger a full review (no stale state).

### 6. Timeout Safety
- Workflow timeout: 10 minutes total.
- CLI invocations: 540s (9 min) for full pipeline, 180s for Track 1 verification.
- Timeouts must not leave the PR in an unreviewed state (fail-closed applies).

### 7. Output Format Resilience
The system must handle multiple Claude CLI output formats. The CLI wraps model responses in a JSON envelope (`{"type":"result","result":"..."}`) where the `.result` field is a string. Models frequently wrap their JSON output in markdown code fences (`` ```json ... ``` ``) despite explicit instructions not to. The extraction layer MUST:
- Strip markdown fences from the `.result` string before JSON parsing
- Apply four strategies in order until one succeeds: direct JSON, envelope `.result` (with fence stripping), content blocks array, embedded JSON in text
- Never assume the model will follow output format instructions perfectly

### 8. Marker-Based Identification
All review bodies and inline comments MUST contain the marker: `<!-- pr-code-review-validator -->`. This marker is used for cleanup identification in subsequent runs.

### 9. Artifact Integrity
Artifacts must be valid JSON, include the SHA of the commit that produced them, a push counter, and the full violation objects with enough data to reconstruct inline comments. Deleted files must be auto-resolved (removed from active violations).

### 10. No Skill-Specific Logic in Infrastructure
Shell scripts and the workflow file must not contain skill-specific rules. All domain knowledge lives in skill files (`.claude/skills/`) and agent prompts. The infrastructure only knows about "domains" and "sub-agents", not specific rules.

### 11. Secrets Validation
The `BEDROCK_BASE_URL` and `PORTKEY_API_KEY` secrets MUST be identical across all repositories using this pipeline. A 403 "Portkey Error: Forbidden" indicates an invalid API key or mismatched base URL. When deploying to a new repository:
- Copy secrets verbatim from the working reference repository (no manual retyping)
- Both secrets must be set as Repository Secrets (not Environment Secrets)
- The `BEDROCK_BASE_URL` must be the Portkey gateway URL, NOT a raw Bedrock endpoint

### 12. Debug Observability
CLI invocations MUST capture stderr to a log file and print the first 500-1000 characters of raw output on failure. Never use `2>/dev/null` on CLI calls — silent failures cause 3-minute timeout hangs with no diagnostic information. On failure, the pipeline must log:
- The actual error message from the CLI (stderr)
- The first 500+ chars of raw output (to see partial responses)
- Key environment variable presence (not values) for debugging

---

## OUTPUT

The system produces the following outputs:

### 1. GitHub PR Review (posted via GitHub API)

**Event:** `REQUEST_CHANGES` (fail) | `COMMENT` (pass/skip)

**Summary body — pass (clean):**
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

**Summary body — fail:**
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

**Summary body — skip:**
```
<!-- pr-code-review-validator -->
## REVIEW SKIPPED — no code files changed

Only non-code files were modified in this PR. No skill-based review needed.
Status: **PASSED**

---
*This review was generated by the PR Code Review Validator.*
```

**Inline comment format (one per violation):**
```
**<skill-name> > <rule>**

<Explanation of WHY the code violates the rule>

**Suggestion:** <Specific, actionable fix>

<!-- pr-code-review-validator -->
```

### 2. Pipeline JSON (internal, used between stages)

```json
{
  "verdict": "pass | fail | skip",
  "summary": "<markdown string>",
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

### 3. Violations Artifact (persisted between runs)

```json
{
  "pr_number": 123,
  "last_push_sha": "abc123...",
  "push_count": 1,
  "active_violations": [
    {
      "path": "relative/path.ts",
      "line": 15,
      "skill": "skill-name",
      "rule": "Rule N: Name",
      "description": "...",
      "suggestion": "...",
      "found_in_push": 1,
      "body": "<full inline comment body>"
    }
  ]
}
```

### 4. Validation Sub-Agent Output (Stage 2)

```json
[
  {
    "skill": "skill-name",
    "rule": "Rule/Category name",
    "scope": "frontend | backend",
    "path": "relative/path.ts",
    "line": 0,
    "description": "What violates the rule and why",
    "suggestion": "Specific fix",
    "severity": "Critical | Recommended"
  }
]
```

### 5. Synthesis Agent Output (Stage 3)

```json
{
  "confirmed_violations": [
    {
      "skill": "...",
      "rule": "...",
      "scope": "...",
      "path": "...",
      "line": 0,
      "body": "<formatted inline comment>"
    }
  ],
  "false_positives": [
    {
      "skill": "...",
      "rule": "...",
      "path": "...",
      "line": 0,
      "reason": "Why this is not a violation in context"
    }
  ]
}
```

### 6. Verification Agent Output (Track 1)

```json
{
  "verified": [
    {
      "id": 0,
      "status": "still_present | resolved",
      "path": "...",
      "line": 0,
      "reason": "Explanation"
    }
  ]
}
```

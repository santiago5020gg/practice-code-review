# GitHub Code Review Integration Pipeline

<Role>
You are a senior DevOps engineer and AI pipeline architect. Your job is to build
a complete GitHub Actions workflow that automatically reviews pull requests using
a multi-agent Claude pipeline (Sonnet for validation, Opus for synthesis).
</Role>

<Context>
The pipeline runs on GitHub Actions (ubuntu-latest) and routes AI traffic through
Portkey → AWS Bedrock. It uses Claude Code CLI in print mode.

Runtime requirements:
- CLI: `@anthropic-ai/claude-code` (invoked with `claude --print --model <model> --output-format json`)
- Tools: `gh` CLI (GitHub API), `jq` (JSON processing)
- Code extensions reviewed: `.ts`, `.tsx`, `.js`, `.jsx`, `.prisma`, `.sql`
- Models: `sonnet` (validation), `opus` (synthesis) — short names only, Portkey resolves them
- Timeouts: 10min workflow total, 540s full pipeline, 180s Track 1 verification

GitHub Repository Secrets required:
| Secret | Purpose |
|--------|---------|
| `BEDROCK_BASE_URL` | Portkey gateway URL |
| `PORTKEY_API_KEY` | Portkey authentication key |

Environment variables set in workflow:
```yaml
ANTHROPIC_BEDROCK_BASE_URL: "${{ secrets.BEDROCK_BASE_URL }}"
ANTHROPIC_CUSTOM_HEADERS: "x-portkey-api-key:${{ secrets.PORTKEY_API_KEY }}\nx-portkey-provider:@aws-bedrock-use2"
CLAUDE_CODE_USE_BEDROCK: "1"
CLAUDE_CODE_SKIP_BEDROCK_AUTH: "1"
```

Review Modes:
- **FULL** — All changed files validated from scratch (first push, force-push, `full-review` label, no prior artifact)
- **INCREMENTAL** — Two tracks on subsequent pushes:
  - Track 1: Re-verify prior violations on touched files (still_present or resolved)
  - Track 2: Full validation of newly changed files without prior violations

Skills live in `.claude/skills/<skill-name>/SKILL.md` and are self-contained. Sub-agents discover
and read them at runtime. Adding a skill requires no infrastructure changes.

Common errors:
- 403 "Forbidden" → Invalid `PORTKEY_API_KEY` or wrong `BEDROCK_BASE_URL`
- 400 "invalid model" → Using full model ID instead of short name
- 3-minute timeout with no output → Secrets misconfigured (silent auth failure)
</Context>

<Criteria>
1. Every PR is validated against the same criteria, regardless of who pushes or when.
2. New review skills can be added without modifying pipeline infrastructure.
3. Use the cheapest model capable of each task (Sonnet validates, Opus synthesizes).
4. Fail-closed: pipeline crash or invalid output always results in `REQUEST_CHANGES`.
5. On subsequent pushes, only re-validate what changed (incremental mode).
6. The system never auto-approves, never auto-fixes, never modifies code.
7. All review comments contain marker `<!-- pr-code-review-validator -->` for cleanup.
8. Single bundled review per run (one notification to PR author).
9. Shell scripts must not contain skill-specific logic — all domain rules live in skills.
10. Do NOT use full model IDs (e.g., `us.anthropic.claude-sonnet-4-6-v1`). Use short names only.
</Criteria>

<Instructions>
1. Create the project structure:
   ```
   .github/workflows/pr-code-review-validator.yml
   scripts/lib/common.sh
   scripts/lib/json-extract.sh
   scripts/detect-review-mode.sh
   scripts/cleanup-prior-reviews.sh
   scripts/run-review-pipeline.sh
   scripts/post-review.sh
   prompts/pipeline-full.md
   prompts/pipeline-incremental-track2.md
   prompts/verification-track1.md
   .claude/skills/  (empty directory, skills added separately)
   ```

2. Build `scripts/lib/common.sh`:
   - Define array of reviewed file extensions: `.ts`, `.tsx`, `.js`, `.jsx`, `.prisma`, `.sql`
   - Define the review marker string: `<!-- pr-code-review-validator -->`
   - Define color constants for terminal logging (RED, GREEN, YELLOW, RESET)
   - Export shared utility functions (log_info, log_error, log_warn)

3. Build `scripts/lib/json-extract.sh`:
   - Implement multi-strategy JSON extraction from Claude CLI output
   - Strategy 1: Direct parse (output is already valid JSON)
   - Strategy 2: Strip markdown code fences (```json ... ```) then parse
   - Strategy 3: Extract first `[...]` or `{...}` block from mixed output
   - Validate extracted JSON with `jq type` before returning
   - Exit with error code if no valid JSON found

4. Build `scripts/detect-review-mode.sh`:
   - Check if push event is force-push (`github.event.forced`) → FULL
   - Check if PR has `full-review` label → FULL
   - Check if `.review-artifacts/violations.json` artifact exists → INCREMENTAL
   - Check if this is the first push (push_count == 0) → FULL
   - Default fallback → FULL
   - Export `REVIEW_MODE=FULL|INCREMENTAL` to `$GITHUB_ENV`

5. Build `scripts/cleanup-prior-reviews.sh`:
   - List all reviews on the PR via `gh api repos/{owner}/{repo}/pulls/{pr}/reviews`
   - Filter reviews whose body contains `<!-- pr-code-review-validator -->`
   - Dismiss any pending review requests from the bot user
   - Minimize/collapse old review comments via GraphQL mutation

6. Build `scripts/run-review-pipeline.sh`:
   - Collect changed files: `git diff --name-only $BASE...$HEAD` filtered by code extensions
   - Exit early with `verdict: skip` if no code files changed
   - If FULL mode:
     a. Read all skill files from `.claude/skills/*/SKILL.md`
     b. Substitute file contents and skills into `prompts/pipeline-full.md` template
     c. Invoke: `claude --print --model sonnet --output-format json < prompt.txt`
     d. Extract violations JSON using `json-extract.sh`
     e. If zero violations → output `{ "verdict": "pass" }` and exit
     f. If violations found → substitute into synthesis prompt
     g. Invoke: `claude --print --model opus --output-format json < synthesis-prompt.txt`
     h. Extract final pipeline JSON and output to stdout
   - If INCREMENTAL mode:
     a. Load prior violations from artifact
     b. Track 1 (parallel): Re-verify prior violations on files in latest push
        - Use `prompts/verification-track1.md` template
        - Invoke with Sonnet, 180s timeout
        - Output: each violation marked `still_present` or `resolved`
     c. Track 2 (parallel): Full validation of new files without prior violations
        - Same flow as FULL mode but scoped to new files only
     d. Merge: Remove resolved violations, add new violations
     e. Output merged pipeline JSON to stdout

7. Build `scripts/post-review.sh`:
   - Read pipeline JSON from stdin or file argument
   - Determine review event: `fail` → `REQUEST_CHANGES`, `pass|skip` → `COMMENT`
   - Build review body with summary + marker comment
   - Post bundled review with inline comments via `gh api`:
     ```
     POST /repos/{owner}/{repo}/pulls/{pr}/reviews
     { event, body, comments: [{path, line, side, body}] }
     ```
   - Write/update `.review-artifacts/violations.json` with current state
   - Log stats: files checked, violations found, false positives filtered

8. Build prompt templates in `prompts/`:
   - `pipeline-full.md`:
     - Placeholders: `{{CODE_FILES}}`, `{{SKILLS_CONTENT}}`
     - Instruct Sonnet to read all files, apply all skills, output violations array
     - Specify exact output JSON schema
   - `pipeline-incremental-track2.md`:
     - Same as full but with `{{NEW_FILES_ONLY}}` scope
   - `verification-track1.md`:
     - Placeholders: `{{PRIOR_VIOLATIONS}}`, `{{CHANGED_FILES}}`
     - Instruct Sonnet to re-check each prior violation
     - Output: same violations with `status: still_present|resolved`

9. Build `.github/workflows/pr-code-review-validator.yml`:
   - Trigger: `pull_request` events (opened, synchronize, reopened)
   - Permissions: `contents: read`, `pull-requests: write`
   - Concurrency: cancel in-progress runs for same PR
   - Steps:
     a. `actions/checkout@v4` with `fetch-depth: 0` (need full history for diff)
     b. Install Claude CLI: `npm install -g @anthropic-ai/claude-code`
     c. Download prior artifact (if exists): `actions/download-artifact@v4`
     d. Run `scripts/detect-review-mode.sh`
     e. Run `scripts/cleanup-prior-reviews.sh`
     f. Run `scripts/run-review-pipeline.sh` with 540s timeout
     g. Run `scripts/post-review.sh`
     h. Upload artifact: `actions/upload-artifact@v4` with 90-day retention
   - Environment: all Portkey/Bedrock variables from secrets
   - Timeout: 10 minutes total (`timeout-minutes: 10`)

10. Test locally:
    ```bash
    bash scripts/test-pipeline-local.sh [base-branch]
    ```
    - Requires: `claude` CLI installed, `jq` available, git repo with changes
    - Simulates the full pipeline without GitHub Actions context
</Instructions>

<Output>
Validation stage output (Sonnet → Opus):
```json
[
  {
    "skill": "<skill-name>",
    "rule": "<rule/category name>",
    "path": "relative/path.ts",
    "line": 15,
    "description": "What violates the rule and why",
    "suggestion": "Specific, actionable fix",
    "severity": "Critical | Recommended"
  }
]
```

Final pipeline output (→ post-review.sh):
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
    "skills_applied": [],
    "violations_found": 0,
    "false_positives_filtered": 0
  }
}
```

Violations artifact (persisted between runs at `.review-artifacts/violations.json`):
```json
{
  "pr_number": 123,
  "last_push_sha": "abc123",
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

GitHub Review API contract:
- Single bundled review (one notification to PR author)
- Event: `REQUEST_CHANGES` (fail) | `COMMENT` (pass/skip)
- All comments contain marker: `<!-- pr-code-review-validator -->`
</Output>

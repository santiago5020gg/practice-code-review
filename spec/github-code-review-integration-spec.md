# GitHub Code Review Integration — Design Spec

> **Purpose:** This spec is the blueprint for building the entire code review pipeline from scratch. Give this document to Claude and it should produce: a GitHub Actions workflow, shell scripts, prompt templates, and all infrastructure needed to automatically review PRs using a multi-agent AI pipeline.
>
> **Prerequisite:** A GitHub repository with code files to review. No prior AI infrastructure required.
>
> **Related:** Once this pipeline is running, use `code-review-skill-factory-spec.md` to build the skill that lets any developer create new review rules.

## Problem

Pull requests were being merged without thorough review. Reviews were either superficial (quick "LGTM" approvals) or entirely absent due to time constraints and resource limitations. This led to inconsistent code quality, undetected security issues, and architectural drift across the codebase.

## Goals

1. **Consistency** — Every PR is validated against the same criteria, regardless of who pushes or when. No PR slips through without review.
2. **Extensibility** — New review rules (skills) can be added by any developer without modifying pipeline infrastructure.
3. **Cost efficiency** — Use the cheapest model capable of each task (validate accurately, synthesize intelligently).
4. **Fail-closed safety** — If the system fails, it blocks the PR rather than silently approving. False positives are preferable to missed bugs.
5. **Incremental efficiency** — On subsequent pushes, only re-validate what changed. Don't waste tokens re-reviewing untouched code.

## Non-Goals

- **No auto-merge** — The system never approves a PR automatically. It only blocks or comments.
- **No human replacement** — This complements human reviewers, not replaces them. Humans still review architecture, business logic, and nuanced decisions.
- **No auto-fix** — The system detects problems and suggests fixes, but never modifies code or pushes commits.
- **No test generation** — Out of scope. This validates existing code against rules, not coverage.
- **No non-code review** — Docs, configs, images, and other non-code files are filtered out and ignored.

## Architecture

### Pipeline Stages

| Stage | Executor | What it does |
|-------|----------|--------------|
| File collection | Bash script | git diff + filter by extension |
| Validation | Sonnet | Reads files + skills, outputs violations JSON |
| Synthesis | Opus (only if violations found) | Filters false positives, formats final review |

### Runtime Environment

- **CI Runtime:** GitHub Actions (ubuntu-latest)
- **AI Gateway:** Portkey → AWS Bedrock (Claude models)
- **CLI:** Claude Code CLI (`@anthropic-ai/claude-code`), invoked in print mode
- **Tools required:** `gh` CLI (GitHub API), `jq` (JSON processing)
- **Code file extensions reviewed:** `.ts`, `.tsx`, `.js`, `.jsx`, `.prisma`, `.sql`
- **Timeouts:** 10 minutes workflow total, 540s full pipeline, 180s Track 1 verification

### Portkey + AWS Bedrock (not direct Anthropic API)

Corporate policy at Perficient requires all AI traffic to route through an approved gateway. Portkey provides:
- Centralized billing under the org's AWS account
- Audit trail for compliance
- Model routing via short names (no Bedrock ARN management)

### Connection Setup

**GitHub Repository Secrets (required):**

| Secret | What it is | Where to get it |
|--------|-----------|-----------------|
| `BEDROCK_BASE_URL` | Portkey gateway URL (NOT a raw Bedrock endpoint) | Portkey dashboard → Gateway → Base URL |
| `PORTKEY_API_KEY` | API key for authenticating with Portkey | Portkey dashboard → API Keys |

These must be set as **Repository Secrets** (not Environment Secrets).

**Environment variables set in the workflow:**

```yaml
ANTHROPIC_BEDROCK_BASE_URL: "${{ secrets.BEDROCK_BASE_URL }}"
ANTHROPIC_CUSTOM_HEADERS: "x-portkey-api-key:${{ secrets.PORTKEY_API_KEY }}\nx-portkey-provider:@aws-bedrock-use2"
CLAUDE_CODE_USE_BEDROCK: "1"
CLAUDE_CODE_SKIP_BEDROCK_AUTH: "1"
```

**Model names in CLI invocations:**

Always use short names — Portkey resolves them to Bedrock model ARNs:
- `sonnet` → Validation stage
- `opus` → Synthesis stage

Do NOT use full model IDs (e.g., `us.anthropic.claude-sonnet-4-6-v1`). Portkey will return 400 errors.

**CLI invocation pattern:**

```bash
claude --print --model <model> --output-format json < prompt.txt > output.json
```

**Common errors:**
- 403 "Forbidden" → Invalid `PORTKEY_API_KEY` or wrong `BEDROCK_BASE_URL`
- 400 "invalid model" → Using full model ID instead of short name
- 3-minute timeout with no output → Secrets misconfigured (silent auth failure)

### Project Structure

```
.github/
└── workflows/
    └── pr-code-review-validator.yml   — GitHub Actions workflow definition

scripts/
├── lib/
│   ├── common.sh                      — Shared constants (extensions, markers, colors)
│   └── json-extract.sh                — Multi-strategy JSON extraction from CLI output
├── detect-review-mode.sh              — Decides FULL vs INCREMENTAL mode
├── cleanup-prior-reviews.sh           — Dismisses/minimizes old bot reviews
├── run-review-pipeline.sh             — Orchestrates validation + synthesis
└── post-review.sh                     — Posts review to GitHub, writes artifact

prompts/
├── pipeline-full.md                   — Prompt template for full validation
├── pipeline-incremental-track2.md     — Prompt template for Track 2 (new files)
└── verification-track1.md             — Prompt template for Track 1 (re-verify)

.claude/
└── skills/                            — Review skills (read by Sonnet at runtime)
    └── <skill-name>/
        └── SKILL.md                   — Self-contained rule definitions

.review-artifacts/
└── violations.json                    — Persisted violations between runs (artifact)
```

### Pipeline Flow

```
PR Event (opened/synchronize/reopened)
  │
  ├─ detect-review-mode.sh → FULL or INCREMENTAL
  │
  ├─ cleanup-prior-reviews.sh → dismiss/minimize old reviews
  │
  ├─ run-review-pipeline.sh
  │     │
  │     ├─ File Collection (bash script)
  │     │     git diff → filter by code extensions → list of files to review
  │     │
  │     ├─ Validation (Sonnet)
  │     │     Read all files + all skills → output violations JSON
  │     │
  │     └─ Synthesis (Opus, only if violations found)
  │           Filter false positives → format inline comments → final verdict
  │
  └─ post-review.sh → post bundled review to GitHub + save artifact
```

### Review Modes

- **FULL** — All changed files validated from scratch. Triggered on: first push, force-push, `full-review` label, no prior artifact.
- **INCREMENTAL** — Two tracks on subsequent pushes:
  - Track 1: Re-verify prior violations on touched files (still_present or resolved)
  - Track 2: Full validation of newly changed files without prior violations
  - Result: Merged state of both tracks

## Interfaces

### 1. Validation Output (Sonnet → Opus)

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

### 2. Final Pipeline Output (→ post-review.sh)

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

### 3. Violations Artifact (persisted between runs)

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

### 4. GitHub Review API Contract

- Single bundled review (one notification to PR author)
- Event: `REQUEST_CHANGES` (fail) | `COMMENT` (pass/skip)
- All comments contain marker: `<!-- pr-code-review-validator -->`


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
3. **Cost efficiency** — Use the cheapest model capable of each task (classify cheaply, validate accurately, synthesize intelligently).
4. **Fail-closed safety** — If the system fails, it blocks the PR rather than silently approving. False positives are preferable to missed bugs.
5. **Incremental efficiency** — On subsequent pushes, only re-validate what changed. Don't waste tokens re-reviewing untouched code.

## Non-Goals

- **No auto-merge** — The system never approves a PR automatically. It only blocks or comments.
- **No human replacement** — This complements human reviewers, not replaces them. Humans still review architecture, business logic, and nuanced decisions.
- **No auto-fix** — The system detects problems and suggests fixes, but never modifies code or pushes commits.
- **No test generation** — Out of scope. This validates existing code against rules, not coverage.
- **No non-code review** — Docs, configs, images, and other non-code files are filtered out and ignored.

## Architecture

### Why Multi-Agent (not single model)

A single Opus call for the entire review was considered first. Problems:
- **Cost:** Opus pricing on every PR for classification + validation + synthesis is prohibitively expensive at scale.
- **Latency:** A single large prompt with all files and all rules takes too long (~5+ min).
- **Context limits:** Large PRs exceed context windows when everything is in one call.

The multi-agent approach delegates each stage to the cheapest capable model:

| Stage | Model | Why this model |
|-------|-------|----------------|
| Classification | Haiku | Simple routing task — fast, cheap |
| Validation | Sonnet | Needs code comprehension but rules are explicit |
| Synthesis | Opus | Needs judgment to filter false positives |

### Runtime Environment

- **CI Runtime:** GitHub Actions (ubuntu-latest)
- **AI Gateway:** Portkey → AWS Bedrock (Claude models)
- **CLI:** Claude Code CLI (`@anthropic-ai/claude-code`), invoked in print mode
- **Tools required:** `gh` CLI (GitHub API), `jq` (JSON processing)
- **Code file extensions reviewed:** `.ts`, `.tsx`, `.js`, `.jsx`, `.prisma`, `.sql`
- **Timeouts:** 10 minutes workflow total, 540s full pipeline, 180s Track 1 verification

### Why Portkey + AWS Bedrock (not direct Anthropic API)

Corporate policy at Perficient requires all AI traffic to route through an approved gateway. Portkey provides:
- Centralized billing under the org's AWS account
- Audit trail for compliance
- Model routing via short names (no Bedrock ARN management)

### Why Fail-Closed

The cost of a false negative (missed bug in production) far exceeds the cost of a false positive (developer dismisses a comment). Therefore:
- Pipeline crash → REQUEST_CHANGES
- Invalid output → REQUEST_CHANGES
- Timeout → REQUEST_CHANGES

### Why Skills as Extension Point

The pipeline infrastructure (workflow, scripts, prompts) should be stable. What changes frequently is *what to check for*. Skills isolate domain knowledge into self-contained Markdown files that sub-agents read at runtime. Adding a skill requires zero infrastructure changes.

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
  │     ├─ Stage 1: Classification (Haiku)
  │     │     Filter non-code → classify by domain → trace related files
  │     │
  │     ├─ Stage 2: Validation (Sonnet sub-agents)
  │     │     One agent per domain → read skill files → output violations JSON
  │     │
  │     └─ Stage 3: Synthesis (Opus, only if violations found)
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

### 1. Skill File Contract

Any skill at `.claude/skills/<name>/SKILL.md` must be self-contained — a sub-agent validates code by reading ONLY that file.

### 2. Validation Sub-Agent Output (Stage 2 → Stage 3)

```json
[
  {
    "skill": "<skill-name>",
    "rule": "<rule/category name>",
    "scope": "frontend | backend",
    "path": "relative/path.ts",
    "line": 15,
    "description": "What violates the rule and why",
    "suggestion": "Specific, actionable fix",
    "severity": "Critical | Recommended"
  }
]
```

### 3. Final Pipeline Output (→ post-review.sh)

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

### 4. Violations Artifact (persisted between runs)

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

### 5. GitHub Review API Contract

- Single bundled review (one notification to PR author)
- Event: `REQUEST_CHANGES` (fail) | `COMMENT` (pass/skip)
- All comments contain marker: `<!-- pr-code-review-validator -->`


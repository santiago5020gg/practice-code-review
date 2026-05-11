# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an **AI-powered PR Code Review Pipeline** that automatically reviews pull requests using a multi-agent Claude architecture. It runs as a GitHub Actions workflow, routing changed files through classification, validation, and synthesis stages to produce inline review comments on PRs.

## Architecture

```
GitHub Actions Workflow (.github/workflows/pr-code-review-validator.yml)
  → detect-review-mode.sh   (decides FULL vs INCREMENTAL)
  → cleanup-prior-reviews.sh (dismiss/minimize old reviews)
  → run-review-pipeline.sh   (orchestrates the 3-stage AI pipeline)
  → post-review.sh           (posts review to GitHub, writes artifact)
```

### Multi-Agent Pipeline (3 Stages)

1. **Classification (Haiku)** — Classifies changed files by domain (frontend/backend), filters non-code, traces related files
2. **Validation (Sonnet sub-agents)** — One per domain, reads skill files from `.claude/skills/<name>/SKILL.md`, validates code against rules, outputs structured violations JSON
3. **Synthesis (Opus, only if violations found)** — Filters false positives, formats inline comments, produces final review

### Review Modes

- **FULL** — Validates all changed files from scratch (default, force-push, first run)
- **INCREMENTAL** — Two-track review on subsequent pushes:
  - Track 1: Re-verifies prior violations on touched files (sonnet)
  - Track 2: Full validation of newly changed files without prior violations (haiku → sonnet → opus)

### Extension Model

Skills are the primary extension point. Each skill lives in `.claude/skills/<skill-name>/SKILL.md` and is self-contained. Adding a skill requires no changes to infrastructure scripts — sub-agents discover and read skill files at runtime.

## Commands

### Run the pipeline locally
```bash
bash scripts/test-pipeline-local.sh [base-branch]
```
Requires: `claude` CLI (`npm install -g @anthropic-ai/claude-code`) and `jq`.

### Run individual scripts
```bash
# Detect review mode (requires git context + env vars)
bash scripts/detect-review-mode.sh

# Run the pipeline (requires REVIEW_MODE, CODE_FILES_JSON, etc.)
bash scripts/run-review-pipeline.sh

# Post review to GitHub (requires GH_TOKEN, PR_NUMBER, etc.)
bash scripts/post-review.sh
```

## Key Configuration

- **Code extensions reviewed:** `.ts`, `.tsx`, `.js`, `.jsx`, `.prisma`, `.sql` (defined in `scripts/lib/common.sh`)
- **Models:** Haiku (classification), Sonnet (validation), Opus (synthesis)
- **Timeouts:** 540s full pipeline, 180s Track 1 verification, 10min workflow total
- **AI Gateway:** Portkey → AWS Bedrock (secrets: `BEDROCK_BASE_URL`, `PORTKEY_API_KEY`)
- **Artifacts:** `.review-artifacts/violations.json` persisted between runs (90-day retention)

## Important Conventions

- All review comments and summaries must contain the marker `<!-- pr-code-review-validator -->` for cleanup identification
- **Fail-closed policy:** Pipeline crash or invalid output always results in `REQUEST_CHANGES` blocking the PR
- Sub-agent violation output schema: `{ skill, rule, scope, path, line, description, suggestion, severity }`
- Shell scripts must not contain skill-specific logic — all domain rules live in `.claude/skills/`

## Project Structure

- `scripts/` — Shell scripts for the pipeline (sourcing `lib/common.sh` and `lib/json-extract.sh`)
- `prompts/` — Prompt templates with `{{PLACEHOLDER}}` substitution for the CLI invocations
- `spec/` — Design specifications for the review system and skill factory
- `docs/superpowers/` — Plans and specs for the superpowers plugin integration
- `.github/workflows/` — GitHub Actions workflow definition
- `hello-app/` — Next.js test project (code files here ARE reviewed by the pipeline since there's no path exclusion)

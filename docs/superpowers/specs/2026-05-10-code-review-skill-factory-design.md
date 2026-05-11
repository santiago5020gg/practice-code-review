# Code Review Skill Factory — Design Spec

## Overview

A Claude Code skill (`/create-review-skill`) that interactively guides users through creating and editing code review skills for the PR Code Review Validator pipeline. Skills are self-contained markdown files that pipeline sub-agents read at runtime to validate code changes.

## Form Factor

- **Type:** Claude Code superpowers-style skill
- **Location:** `.claude/skills/create-review-skill/SKILL.md`
- **Invocation:** `/create-review-skill` or `/create-review-skill <existing-skill-name>`
- **Target:** Generic/multi-repo — skills should be language-agnostic in structure

## Architecture

### How Skills Connect to the Pipeline

```
Skill Factory (this skill)
  │
  │ creates/edits files on disk
  ▼
.claude/skills/<name>/SKILL.md  (+optional reference.md)
  │
  │ committed to repo
  ▼
Pipeline runs on PR (GitHub Actions)
  │
  ├─ Orchestrator (Haiku) scans .claude/skills/*/SKILL.md
  ├─ Reads ## Scope section of each skill
  ├─ Matches changed PR files against scope globs
  ├─ For each skill with matching files → spawns Sonnet sub-agent
  │     Sub-agent reads SKILL.md, validates files, returns violations JSON
  ▼
  Synthesizer (Opus) filters false positives → posts review to GitHub
```

### Integration Model: Convention-Based

- Skills declare their own scope (paths/extensions) in the SKILL.md file
- The pipeline discovers skills dynamically by scanning `.claude/skills/*/SKILL.md`
- No registry file, no per-skill config, no prompt edits per skill
- Adding a new skill = adding files to the skills directory. Removal = deleting the directory.

### Prerequisite (One-Time)

The pipeline prompts (`prompts/pipeline-full.md`, `prompts/pipeline-incremental-track2.md`) must be updated to support dynamic skill discovery. This is NOT part of the Skill Factory's runtime — it's a one-time infrastructure change.

## Entry Behavior

1. Scan `.claude/skills/` for existing review skill directories (exclude `create-review-skill` itself)
2. If an argument is provided (e.g., `/create-review-skill api-error-handling`):
   - Skill exists → **Edit mode**
   - Skill doesn't exist → **Create mode** with that name as starting point
3. No argument → ask "What do you want the code review to check for?" → **Create mode**

## Create Mode Flow

### Step 1 — Gather Intent

Ask: "Describe what you want the code review to check for."
Accept free-text description.

### Step 2 — Clarifying Questions (one at a time, minimum 2)

Questions adapt to context but typically cover:
- **File scope:** What file types/paths does this apply to?
- **Violation boundary:** What counts as a violation vs. acceptable?
- **Severity:** Should violations block merge (Critical) or suggest (Recommended)?
- **Exceptions:** Cases where the rule should NOT fire (test files, generated code, etc.)
- **Fix example:** What does the ideal fix look like?

### Step 3 — Propose Skill Definition

Present complete skill structure for approval:
- Skill name (kebab-case)
- Scope (paths, extensions, excludes)
- Each rule: name, description, severity, violation condition, correct condition, code examples
- Whether a `reference.md` is warranted (offer if >3 rules or complex edge cases)

### Step 4 — User Confirms

Wait for explicit approval. Iterate if changes requested.

### Step 5 — Generate Files

Write `.claude/skills/<name>/SKILL.md` (and optionally `reference.md`).
Commit: `feat: add <skill-name> code review skill`

### Step 6 — Structural Validation

Run validation checklist (see below). Fix issues inline.

### Step 7 — Summary

Display: skill path, rules count, scope, activation note.

## Edit Mode Flow

### Step 1 — Load & Display

Read existing SKILL.md and display summary: current rules (numbered, with severity), scope, whether reference.md exists.

### Step 2 — Ask What to Change

Present options (multi-select):
- Add new rule(s)
- Modify an existing rule (severity, examples, description)
- Remove a rule
- Change scope (paths/extensions/excludes)
- Add/update reference.md

### Step 3 — Guided Edit

For each selected action, ask targeted questions. For "add new rule," follow create mode's clarification flow scoped to just the new rule.

### Step 4 — Present Updated Skill

Show diff-style summary: old → new for modified rules, additions highlighted.

### Step 5 — User Confirms

Wait for approval.

### Step 6 — Write & Validate

Update file, run structural validation, commit: `feat: update <skill-name> code review skill`

## Generated File Format

### SKILL.md

```markdown
---
name: <skill-name>
description: <one-line description of what this skill checks>
when_to_use: "TRIGGER when: <file path/extension conditions>. SKIP when: <exclusions>"
effort: medium
user-invocable: false
---

# <Skill Display Name>

## Scope

**Applies to:** `<glob patterns>` (e.g., `**/*.ts`, `src/api/**`)
**Excludes:** `<exclusion patterns>` (e.g., `*.test.*`, `*.spec.*`, `__mocks__/`)
**Extensions:** <list> (e.g., .ts, .tsx, .py)

## Rules

### Rule 1: <Name>
**Severity:** Critical | Recommended
**Description:** <what this rule checks for>
**Violation:** <condition that triggers a finding>
**Correct:** <what compliant code looks like>

**Example violation:**
(fenced code block in target language showing violating code)

**Example fix:**
(fenced code block in target language showing corrected code)

### Rule 2: <Name>
...
```

### reference.md (optional)

- Extended examples for complex rules
- Edge case documentation
- Anti-patterns gallery
- No frontmatter needed

### When to offer reference.md

- Skill has >3 rules
- Rules have complex edge cases
- User provides many examples during brainstorming
- Domain requires extended explanation

## Structural Validation

After generating skill files, verify:

1. YAML frontmatter is parseable and contains required fields (`name`, `description`, `when_to_use`)
2. `name` is kebab-case and matches the directory name
3. `## Scope` section exists with at least one glob pattern
4. At least one `### Rule N:` section exists
5. Each rule has all required subsections: Severity, Description, Violation, Correct, Example violation, Example fix
6. Severity values are exactly "Critical" or "Recommended"
7. Code examples have language-specific fences (not bare ```)
8. No duplicate rule numbers

**On failure:** Report which checks failed, fix inline, re-validate.
**On success:** Proceed to commit and summary.

## Scope & Boundaries

### What the Skill Factory IS

- An interactive Claude Code skill for creating/editing review skills
- A generator of well-structured SKILL.md files
- A validator ensuring skills meet pipeline structural requirements

### What it is NOT

- Does not modify pipeline scripts or workflow files
- Does not perform code review itself
- Does not manage sub-agent concurrency (pipeline handles that)
- Does not handle pipeline prerequisites (Portkey/Bedrock, CLI)

### Limitations

- Skills are language-agnostic in structure; examples use target language
- No inter-skill dependency (each skill is self-contained)
- Maximum recommended: ~10 rules per skill (beyond that, suggest splitting)

## Naming Convention

- Kebab-case, descriptive, unique within the project
- Examples: `no-console-log`, `api-error-boundaries`, `parameterized-queries`, `react-hooks-rules`

## Success Criteria

1. A user with no knowledge of the pipeline internals can create a working review skill in <5 minutes
2. Every generated skill passes structural validation on first attempt
3. Skills created by the factory are automatically picked up by the pipeline on the next PR
4. Edit mode allows incremental changes without regenerating the entire skill
5. The factory never modifies pipeline infrastructure files

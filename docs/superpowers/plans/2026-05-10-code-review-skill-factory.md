# Code Review Skill Factory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a Claude Code skill (`/create-review-skill`) that interactively guides users through creating and editing code review skills for the PR Code Review Validator pipeline.

**Architecture:** Single self-contained skill file that handles both create and edit flows. The skill uses conversational Q&A to gather requirements, proposes a structured skill definition, generates SKILL.md files upon approval, validates their structure, and commits them.

**Tech Stack:** Claude Code skill (Markdown with frontmatter), Bash (git commands), no external dependencies.

---

## File Structure

```
.claude/skills/create-review-skill/
  SKILL.md    — The skill definition (invocation, flow, generation logic, validation)
```

This is the only file to create. The skill generates other files at runtime (`.claude/skills/<name>/SKILL.md` etc.) but those are outputs, not part of this implementation.

---

## Task 1: Create the Skill File with Frontmatter and Entry Logic

**Files:**
- Create: `.claude/skills/create-review-skill/SKILL.md`

- [ ] **Step 1: Create the skill directory**

```bash
mkdir -p .claude/skills/create-review-skill
```

- [ ] **Step 2: Write the skill file with frontmatter and entry section**

Create `.claude/skills/create-review-skill/SKILL.md` with this content:

```markdown
---
name: create-review-skill
description: Interactive factory for creating and editing code review skills that the PR Code Review Validator pipeline enforces on pull requests
when_to_use: "TRIGGER when: user wants to create a new code review rule, add a review skill, edit an existing review skill, or asks about automated code review enforcement. SKIP when: user wants to perform a code review themselves, or asks about the pipeline infrastructure."
effort: medium
user-invocable: true
---

# Code Review Skill Factory

You are an interactive skill factory that helps users create and edit code review skills for the PR Code Review Validator pipeline. You guide users through defining what to check, refine requirements through conversation, generate well-structured skill files, validate them, and commit them.

You do NOT perform code review yourself. You CREATE the rules and agents that perform code review autonomously on every PR.

## Entry Logic

When invoked, determine the mode:

1. Scan `.claude/skills/` for existing review skill directories (exclude `create-review-skill` itself)
2. If the user provided an argument (e.g., `/create-review-skill api-error-handling`):
   - If a directory `.claude/skills/<argument>/SKILL.md` exists → enter **Edit Mode**
   - If it doesn't exist → enter **Create Mode** using the argument as the initial skill name
3. If no argument was provided:
   - If existing skills were found, briefly list them and ask: "Would you like to edit an existing skill, or create a new one?"
   - If no skills exist, ask: "What do you want the code review to check for?"
   - Enter the appropriate mode based on the answer
```

- [ ] **Step 3: Verify the file exists and frontmatter is valid**

```bash
head -8 .claude/skills/create-review-skill/SKILL.md
```

Expected: Shows the `---` fenced frontmatter with name, description, when_to_use fields.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/create-review-skill/SKILL.md
git commit -m "feat(skill-factory): add skill file with frontmatter and entry logic"
```

---

## Task 2: Add Create Mode Flow

**Files:**
- Modify: `.claude/skills/create-review-skill/SKILL.md`

- [ ] **Step 1: Append the Create Mode section to the skill file**

Append the following after the Entry Logic section:

```markdown

## Create Mode

### Step 1 — Gather Intent

Ask the user: "Describe what you want the code review to check for."

Accept any free-text description. Examples of valid inputs:
- "I want to ensure all API calls use error boundaries"
- "No console.log in production code"
- "All components must have prop types defined"
- "Database queries must use parameterized queries"

### Step 2 — Clarifying Questions

Ask questions ONE AT A TIME (minimum 2 before proposing). Adapt to context but cover:

1. **File scope:** "What file types or paths should this apply to?" Offer common patterns as choices:
   - `**/*.ts` / `**/*.tsx` (all TypeScript)
   - `src/api/**` / `pages/api/**` (API routes)
   - `src/components/**` (React components)
   - Custom pattern (let user specify)

2. **Violation boundary:** "What exactly counts as a violation? Are there cases that look similar but should be allowed?"

3. **Severity:** "Should violations block the PR (Critical) or just suggest improvements (Recommended)?"
   - Critical = PR cannot merge until fixed
   - Recommended = Shows as a suggestion, does not block

4. **Exceptions:** "Are there cases where this rule should NOT fire?" Common exceptions:
   - Test files (`*.test.*`, `*.spec.*`)
   - Generated code
   - Third-party vendored files
   - Specific directories

5. **Fix example:** "Can you show me what the ideal fix looks like? (paste a code snippet if possible)"

Stop asking when you have enough to fully define the rules. Typically 2-4 questions suffice.

### Step 3 — Propose Skill Definition

Present the complete skill structure for approval:

```
Proposed skill: <skill-name>

Scope:
  Applies to: <glob patterns>
  Excludes: <exclusion patterns>
  Extensions: <list>

Rules:
  Rule 1: <Name>
    Severity: Critical | Recommended
    Violation: <what triggers>
    Correct: <what's acceptable>
    Example violation: <code>
    Example fix: <code>

  Rule 2: ...

Reference doc needed: Yes/No (reason)
```

Ask: "Does this look right? I can adjust any part before generating the files."

### Step 4 — User Confirms

Wait for explicit approval ("yes", "looks good", "go ahead", etc.).
If the user requests changes, update the proposal and re-present.

### Step 5 — Generate Files

Write `.claude/skills/<skill-name>/SKILL.md` using the SKILL.md Template (see below).
If reference.md was approved, also generate it.

### Step 6 — Structural Validation

After writing, verify the generated file passes ALL checks:

1. YAML frontmatter is parseable with required fields (name, description, when_to_use)
2. `name` field is kebab-case and matches the directory name
3. `## Scope` section exists with at least one glob pattern
4. At least one `### Rule N:` heading exists
5. Each rule has ALL subsections: Severity, Description, Violation, Correct, Example violation, Example fix
6. Severity values are exactly "Critical" or "Recommended"
7. Code examples use language-specific fences (not bare ```)
8. No duplicate rule numbers

If any check fails: report it, fix inline, re-validate.

### Step 7 — Commit and Summarize

Commit: `feat: add <skill-name> code review skill`

Display summary:
```
✓ Skill created: .claude/skills/<skill-name>/SKILL.md
  Rules: N rules (X Critical, Y Recommended)
  Scope: <paths>
  
  This skill will activate on the next PR that touches matching files.
```
```

- [ ] **Step 2: Verify the section was appended correctly**

```bash
grep -c "## Create Mode" .claude/skills/create-review-skill/SKILL.md
```

Expected: `1`

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/create-review-skill/SKILL.md
git commit -m "feat(skill-factory): add create mode flow"
```

---

## Task 3: Add Edit Mode Flow

**Files:**
- Modify: `.claude/skills/create-review-skill/SKILL.md`

- [ ] **Step 1: Append the Edit Mode section to the skill file**

Append after the Create Mode section:

```markdown

## Edit Mode

### Step 1 — Load & Display

Read the existing `.claude/skills/<skill-name>/SKILL.md` and display:

```
Existing skill: <skill-name>
Description: <from frontmatter>

Scope:
  Applies to: <globs>
  Excludes: <exclusions>

Rules:
  1. <Name> (Critical)
  2. <Name> (Recommended)
  ...

Reference doc: exists / not present
```

### Step 2 — Ask What to Change

Ask: "What would you like to change?" Present options:

1. Add new rule(s)
2. Modify an existing rule (change severity, update examples, refine description)
3. Remove a rule
4. Change scope (paths/extensions/excludes)
5. Add or update reference.md

The user can select multiple.

### Step 3 — Guided Edit

For each selected action:

**Add new rule:** Follow Create Mode Step 2 questions scoped to just the new rule, then integrate it into the existing rules (assign next rule number).

**Modify a rule:** Ask which rule (by number or name), then ask what to change. Show old → new for confirmation.

**Remove a rule:** Ask which rule, confirm removal, renumber remaining rules.

**Change scope:** Show current scope, ask what to add/remove/replace.

**Add/update reference.md:** Ask what content to include (extended examples, edge cases, anti-patterns).

### Step 4 — Present Changes

Show a summary of what changed:

```
Changes to <skill-name>:
  [+] Added Rule 4: <Name> (Recommended)
  [~] Modified Rule 2: severity Critical → Recommended
  [-] Removed Rule 3: <Name>
  [~] Scope: added `src/hooks/**`
```

Ask: "Apply these changes?"

### Step 5 — User Confirms

Wait for approval. If changes requested, return to Step 3.

### Step 6 — Write, Validate & Commit

Update the SKILL.md file with all changes.
Run the same structural validation as Create Mode Step 6.
Commit: `feat: update <skill-name> code review skill`

Display:
```
✓ Skill updated: .claude/skills/<skill-name>/SKILL.md
  Changes: <summary of what changed>
  Rules: N rules (X Critical, Y Recommended)
```
```

- [ ] **Step 2: Verify the section was appended**

```bash
grep -c "## Edit Mode" .claude/skills/create-review-skill/SKILL.md
```

Expected: `1`

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/create-review-skill/SKILL.md
git commit -m "feat(skill-factory): add edit mode flow"
```

---

## Task 4: Add SKILL.md Template and Reference.md Template

**Files:**
- Modify: `.claude/skills/create-review-skill/SKILL.md`

- [ ] **Step 1: Append the templates section**

Append after the Edit Mode section:

```markdown

## SKILL.md Template

When generating a new skill, use this exact structure:

```
---
name: {skill-name}
description: {one-line description of what this skill checks}
when_to_use: "TRIGGER when: files match {scope patterns}. SKIP when: {exclusions}"
effort: medium
user-invocable: false
---

# {Skill Display Name}

## Scope

**Applies to:** {glob patterns} (e.g., `**/*.ts`, `src/api/**`)
**Excludes:** {exclusion patterns} (e.g., `*.test.*`, `*.spec.*`, `__mocks__/`)
**Extensions:** {list} (e.g., .ts, .tsx, .py)

## Rules

### Rule 1: {Name}
**Severity:** {Critical | Recommended}
**Description:** {what this rule checks for}
**Violation:** {condition that triggers a finding}
**Correct:** {what compliant code looks like}

**Example violation:**
{fenced code block in target language showing bad code}

**Example fix:**
{fenced code block in target language showing corrected code}
```

Repeat the Rule section for each rule. Number sequentially (Rule 1, Rule 2, ...).

## reference.md Template

When generating a reference doc, use this structure:

```
# {Skill Display Name} — Reference

## Extended Examples

### {Rule Name}

#### Edge Case: {description}
{code example showing the edge case and how to handle it}

#### Anti-Pattern: {description}
{code example showing what NOT to do and why}

## FAQ

### Q: {common question about when the rule applies}
A: {clear answer with example if helpful}
```

Offer to create reference.md when:
- The skill has more than 3 rules
- Rules have complex edge cases discussed during brainstorming
- The user provides many examples that don't fit in the main SKILL.md
- The domain requires extended explanation for sub-agents to validate correctly

## Naming Convention

Skill names MUST be:
- kebab-case (lowercase, hyphens between words)
- Descriptive of what the skill checks (not what it allows)
- Unique within the project
- 2-4 words typical

Examples: `no-console-log`, `api-error-boundaries`, `parameterized-queries`, `react-hooks-rules`, `no-hardcoded-secrets`
```

- [ ] **Step 2: Verify templates were added**

```bash
grep -c "## SKILL.md Template" .claude/skills/create-review-skill/SKILL.md
grep -c "## reference.md Template" .claude/skills/create-review-skill/SKILL.md
grep -c "## Naming Convention" .claude/skills/create-review-skill/SKILL.md
```

Expected: `1` for each.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/create-review-skill/SKILL.md
git commit -m "feat(skill-factory): add SKILL.md and reference.md templates"
```

---

## Task 5: Add Validation Rules and Pipeline Context

**Files:**
- Modify: `.claude/skills/create-review-skill/SKILL.md`

- [ ] **Step 1: Append validation and context sections**

Append after the Naming Convention section:

```markdown

## Structural Validation Checklist

After generating or editing a skill file, verify ALL of these. Fix any failures inline before committing.

| # | Check | How to verify |
|---|-------|---------------|
| 1 | Frontmatter parseable | Has opening and closing `---`, contains `name`, `description`, `when_to_use` |
| 2 | Name matches directory | `name` field in frontmatter == directory name under `.claude/skills/` |
| 3 | Scope section exists | File contains `## Scope` with at least one glob pattern |
| 4 | Has rules | At least one `### Rule N:` heading exists |
| 5 | Rules complete | Each rule has: Severity, Description, Violation, Correct, Example violation, Example fix |
| 6 | Severity valid | Every Severity line is exactly "Critical" or "Recommended" |
| 7 | Code fences have language | No bare ``` — all code fences specify a language (e.g., ```typescript) |
| 8 | No duplicate numbers | Rule numbers are sequential with no repeats |

## Pipeline Context

Skills created by this factory are consumed by the PR Code Review Validator pipeline:

1. On every PR, the pipeline orchestrator scans `.claude/skills/*/SKILL.md`
2. For each skill, it reads the `## Scope` section to determine which files match
3. Changed files are matched against all skill scopes (a file can match multiple skills)
4. For each skill with matching files, a Sonnet sub-agent validates those files against ALL rules
5. Violations are returned as structured JSON:
   ```json
   {
     "skill": "<skill-directory-name>",
     "rule": "<rule name from SKILL.md>",
     "scope": "<domain>",
     "path": "<relative file path>",
     "line": "<line number>",
     "description": "<what violates the rule and why>",
     "suggestion": "<specific actionable fix>",
     "severity": "Critical | Recommended"
   }
   ```
6. An Opus synthesis agent filters false positives and posts the review to GitHub

The sub-agent reads ONLY the skill's own files to perform validation. Each skill must be fully self-contained.

## Constraints

- Never create a skill with 0 rules
- Never set severity to anything other than "Critical" or "Recommended"
- Never create inter-skill dependencies (each skill stands alone)
- If a skill would need more than 10 rules, suggest splitting into multiple skills
- Always ask at least 2 clarifying questions before proposing a skill
- Always get user confirmation before writing files
- Always run structural validation before committing
- Always commit after successful creation/edit
```

- [ ] **Step 2: Verify the sections were added**

```bash
grep -c "## Structural Validation Checklist" .claude/skills/create-review-skill/SKILL.md
grep -c "## Pipeline Context" .claude/skills/create-review-skill/SKILL.md
grep -c "## Constraints" .claude/skills/create-review-skill/SKILL.md
```

Expected: `1` for each.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/create-review-skill/SKILL.md
git commit -m "feat(skill-factory): add validation checklist, pipeline context, and constraints"
```

---

## Task 6: Final Validation of the Complete Skill

**Files:**
- Read: `.claude/skills/create-review-skill/SKILL.md`

- [ ] **Step 1: Verify the complete skill file structure**

```bash
wc -l .claude/skills/create-review-skill/SKILL.md
```

Expected: Between 250-350 lines (the skill is comprehensive but not bloated).

- [ ] **Step 2: Verify all major sections exist**

```bash
grep "^## " .claude/skills/create-review-skill/SKILL.md
```

Expected output (these sections in order):
```
## Entry Logic
## Create Mode
## Edit Mode
## SKILL.md Template
## reference.md Template
## Naming Convention
## Structural Validation Checklist
## Pipeline Context
## Constraints
```

- [ ] **Step 3: Verify frontmatter is complete**

```bash
head -6 .claude/skills/create-review-skill/SKILL.md
```

Expected: Shows `---` / `name: create-review-skill` / `description:` / `when_to_use:` / `effort:` / `user-invocable: true` / `---`

- [ ] **Step 4: Test that the skill is discoverable by Claude Code**

The skill should appear when the user types `/create-review-skill`. Verify the file is in the correct location:

```bash
ls .claude/skills/create-review-skill/SKILL.md
```

Expected: File exists.

- [ ] **Step 5: Commit (if any fixes were needed)**

If validation revealed issues and fixes were applied:

```bash
git add .claude/skills/create-review-skill/SKILL.md
git commit -m "fix(skill-factory): address validation issues"
```

If no fixes needed, skip this step.

---

## Summary

After all tasks are complete:
- `.claude/skills/create-review-skill/SKILL.md` exists with all sections
- The skill is invocable via `/create-review-skill` in Claude Code
- It supports both Create and Edit modes
- It generates valid SKILL.md files with proper frontmatter, scope, and rules
- It validates generated files against 8 structural checks
- It commits results automatically after user approval

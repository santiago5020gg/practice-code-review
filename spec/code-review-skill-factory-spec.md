# Code Review Skill Factory — Design Spec

> **Purpose:** This spec is the blueprint for building a Claude Code skill. Give this document to Claude and it should produce: a skill file (`.claude/skills/create-review-skill/SKILL.md`) that, when invoked via `/create-review-skill`, interactively guides any developer through creating new code review skills for the pipeline.
>
> **Prerequisite:** The code review pipeline from `github-code-review-integration-spec.md` must already be built and running. This skill produces review rules that plug into that pipeline.
>
> **Related:** Build the pipeline first using `github-code-review-integration-spec.md`, then use this spec to create the skill factory.

## Problem

Creating review skills manually is error-prone and requires intimate knowledge of the pipeline's internal structure (JSON schemas, sub-agent configuration, classification routing). This makes it inaccessible to most developers on the team who want to add review rules but don't maintain the pipeline infrastructure.

## Goals

1. **Democratized skill creation** — Any developer on the team can create a new review skill without understanding pipeline internals.
2. **Guided refinement** — Initial rule descriptions are always incomplete. The factory must ask clarifying questions before generating a skill (mandatory brainstorming).
3. **Correct by construction** — Generated skills must conform to the exact schema the pipeline expects. No manual JSON wiring.
4. **Automatic integration** — Once a skill is created, it's immediately active on the next PR. No separate deployment step.

## Non-Goals

- **Does not execute reviews** — The factory creates rules; the pipeline enforces them. Separate concerns.
- **Does not modify existing skills** — Scope is limited to creating new skills. Editing existing ones is a different workflow.
- **Does not manage deployment/CI** — No workflow modifications, no secret management, no infrastructure changes.
- **Does not validate skill quality over time** — No metrics on false-positive rates per skill. That's a future concern.

## Architecture

### Why Interactive (not template-based)

A template approach (fill-in-the-blanks YAML) was considered. Problems:
- Users don't know what makes a good rule until they think through edge cases.
- Templates produce vague rules ("code should be clean") that generate false positives.
- No opportunity to refine scope, severity, or exceptions.

The interactive approach ensures every skill has been thought through before creation.

### Why Mandatory Brainstorming

The first description a user gives is always incomplete. Examples:
- "No console.log" → What about debug builds? What about server-side logging? What about test files?
- "All components need types" → Props types? Return types? Internal state types? Third-party components?

Requiring at least 2 clarifying questions before generating ensures the skill covers real-world edge cases and doesn't produce excessive false positives.

### Why Self-Contained Skills

Each skill must be readable by a sub-agent in isolation. No cross-skill dependencies because:
- Sub-agents may run in parallel with different skill assignments
- A broken skill should not affect other skills
- Skills can be added/removed independently

### Factory Flow

```
User describes intent (natural language)
  │
  ├─ Clarifying questions (minimum 2)
  │     What file types? What counts as violation?
  │     What severity? What exceptions?
  │
  ├─ Propose skill structure
  │     Name, rules, examples → user confirms
  │
  ├─ Generate SKILL.md
  │     Frontmatter + rules + examples + scope
  │
  ├─ Configure sub-agent
  │     How many agents? (default: 1)
  │     Which paths/patterns?
  │
  └─ Integration
        Classification mapping + sub-agent prompt → active on next PR
```

### Cost-Aware Agent Recommendations

When deciding sub-agent count for a new skill:

| Condition | Recommendation | Reason |
|-----------|---------------|--------|
| < 10 rules | 1 agent | Lower token cost, simpler orchestration |
| 10+ rules OR many files in scope | 2-3 agents | Parallel validation, faster execution |
| Never | > 3 agents | Diminishing returns, complexity overhead |

## Interfaces

### 1. Input: User Intent

Free-text description of what the review should check for. Examples:
- "I want to ensure all API calls use error boundaries"
- "No console.log in production code"
- "Database queries must use parameterized queries"

### 2. Output: Skill File (`.claude/skills/<name>/SKILL.md`)

The generated skill must follow the Claude Code skill format:

```yaml
---
name: <kebab-case-name>
description: <one-line summary>
when_to_use: "TRIGGER when: <conditions>. SKIP when: <exclusions>"
effort: high|medium|low
user-invocable: false
---
```

Body structure (all sections required):

```markdown
# <Skill Display Name>

## Scope
Applies to files matching: <glob patterns>

## Rules

### Rule 1: <Name>
**Severity:** Critical | Recommended
**Description:** <what this rule checks>
**Violation:** <what triggers a finding>
**Correct:** <what the code should look like>

**Example violation:**
\```typescript
// bad code
\```

**Example fix:**
\```typescript
// good code
\```
```

Each rule must include: severity, description, violation criteria, correct pattern, example violation code, and example fix code.

### 3. Output: Classification Mapping

```json
{
  "skill": "<skill-name>",
  "paths": ["src/api/", "lib/"],
  "extensions": [".ts", ".tsx"],
  "excludes": ["*.test.*", "*.spec.*"],
  "agents": 1
}
```

### 4. Output: Sub-Agent Prompt Segment

Injected into Stage 2 of the pipeline. Tells the sub-agent:
- Which skill files to read
- Which files to validate
- Output format (standard violation JSON schema)

### 5. Relationship to Pipeline

```
┌─────────────────────────────┐
│     Skill Factory           │  ← Creates skills
│  (interactive, one-time)    │
└──────────────┬──────────────┘
               │ produces
               ▼
┌─────────────────────────────┐
│   .claude/skills/<name>/    │  ← Skill files (static)
│         SKILL.md            │
└──────────────┬──────────────┘
               │ read by
               ▼
┌─────────────────────────────┐
│   Code Review Pipeline      │  ← Runs on every PR
│  (automated, continuous)    │
└─────────────────────────────┘
```


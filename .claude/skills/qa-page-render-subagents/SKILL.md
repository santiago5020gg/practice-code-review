---
name: qa-page-render-subagents
description: "Use when QA testing the hello-app requires parallel page verification across multiple routes — delegates each page check to a model-specific subagent and synthesizes a unified report. TRIGGER when: user requests parallel QA testing or multi-page render verification for the hello-app. SKIP when: user wants single-page sequential testing, code review, or static analysis."
effort: medium
user-invocable: true
---

# QA Page Render Check — Subagent Delegation

## Role

You are a QA orchestrator. Your job is to delegate page rendering checks to subagents running in parallel, collect their results, and produce a unified report.

## Context

The application under test is a Next.js app located at:
`hello-app/src/app/`

Pages to validate:
- `/todos` — displays a list of todo items with checked/unchecked states
- `/hello` — displays a greeting message

The dev server must be running at `http://localhost:3000` before testing begins.

## Prerequisites

- Dev server running at `http://localhost:3000`
- `chrome-devtools` MCP server available and connected

## Criteria
0. Use the MCP `chrome-devtools` tool to interact with the browser.
1. The dev server must be running at `http://localhost:3000` before testing begins.
2. Every assertion must be performed visually through the browser — do not rely on reading source code alone.
3. Delegate `/todos` validation to a **Sonnet 4.6** subagent.
4. Delegate `/hello` validation to a **Haiku** subagent.
5. Both subagents MUST run in parallel — do not wait for one to finish before starting the other.
6. Once both subagents return results, synthesize a unified QA report.


## Subagent Instructions

### Sonnet 4.6 — `/todos`

Model: `sonnet`
Target: `http://localhost:3000/todos`

Steps:
1. Open a new browser window via `chrome-devtools`.
2. Navigate to `http://localhost:3000/todos`.
3. Verify the page renders without console errors.
4. Scroll to 50% of the page — confirm no errors occur during scroll.
5. Scroll to the bottom — verify the text "ipsam aperiam voluptates qui" is **not** checked.
6. Scroll back to the top — verify the first visible heading is "Todos".
7. Verify that checked items use a `<span>` with classes: `w-4 h-4 rounded border bg-green-500 border-green-600`.

Expected return format:

```markdown
### /todos

| Check | Result |
|-------|--------|
| Page renders without console errors | PASS/FAIL |
| Scroll to 50% — no errors | PASS/FAIL |
| Scroll to bottom — "ipsam aperiam voluptates qui" is NOT checked | PASS/FAIL |
| Scroll to top — first heading is "Todos" | PASS/FAIL |
| Checked items use correct CSS classes | PASS/FAIL (details) |

#### Issues Found
(List any failures or anomalies, or "None")
```

### Haiku — `/hello`

Model: `haiku`
Target: `http://localhost:3000/hello`

Steps:
1. Open a new browser window via `chrome-devtools`.
2. Navigate to `http://localhost:3000/hello`.
3. Verify the page renders without console errors.
4. Verify the page displays the text "Hello!".

Expected return format:

```markdown
### /hello

| Check | Result |
|-------|--------|
| Page renders without console errors | PASS/FAIL |
| Page displays "Hello!" text | PASS/FAIL |

#### Issues Found
(List any failures or anomalies, or "None")
```

## Execution Order

1. Dispatch both subagents (`/todos` Sonnet and `/hello` Haiku) **in parallel** using the Agent tool in a single message.
2. Wait for BOTH subagents to return their results.
3. Combine results into a unified report following the Output format below.

## Output

Create folder `hello-app/report-QA/` if it does not exist.
Write a report file (`hello-app/report-QA/report.md`) with:

```markdown
## Pages Reviewed

| Page | URL |
|------|-----|
| Todos | http://localhost:3000/todos |
| Hello | http://localhost:3000/hello |

## Results

### /todos
(Results table from Sonnet subagent)

### /hello
(Results table from Haiku subagent)

## Issues Found
(Consolidated list of failures across all pages, or "None")

## Summary
- **Total pages tested:** N
- **Total checks:** N
- **Passed:** N
- **Failed:** N
- **Total testing time:** (elapsed from first browser open to last assertion)
```

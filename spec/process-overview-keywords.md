# Process Overview — From Spec to Implementation

## Phase 1: Design & Architecture

- Problem definition → automated PR code review with AI
- Multi-agent architecture design (Orchestrator, Classifier, Validators, Synthesizer)
- Model selection per stage (Haiku → cheap/fast classification, Sonnet → validation, Opus → synthesis)
- Review modes design (FULL vs INCREMENTAL)
- Extension model → pluggable skills (zero infra changes to add rules)
- Infrastructure decisions → GitHub Actions + Portkey gateway + AWS Bedrock
- Spec documents written (`github-code-review-integration-design.md`)

## Phase 2: Implementation Plan

- Break spec into implementable units
- Identify shared libraries needed (constants, JSON extraction)
- Define script boundaries (detect mode → cleanup → run pipeline → post review)
- Prompt template design with placeholder substitution
- Output schema definition (violation JSON structure)

## Phase 3: Core Infrastructure Build

- Shared constants library (`lib/common.sh`) → file extensions, markers, timeouts
- JSON extraction utility (`lib/json-extract.sh`) → parse CLI output reliably
- Review mode detection script → git diff analysis, FULL vs INCREMENTAL logic
- Cleanup script → dismiss/minimize prior bot reviews on re-push
- Pipeline orchestration script → stage routing, sub-agent dispatch, timeout handling
- Post-review script → GitHub API calls, artifact persistence

## Phase 4: Prompt Engineering

- Full pipeline prompt (`pipeline-full.md`) → 3-stage orchestration instructions
- Incremental Track 1 prompt (`verification-track1.md`) → re-verify prior violations
- Incremental Track 2 prompt (`pipeline-incremental-track2.md`) → validate new changes only
- Placeholder substitution pattern (`{{CODE_FILES_JSON}}`, `{{SKILLS_PATH}}`, etc.)

## Phase 5: CI/CD Integration

- GitHub Actions workflow (`pr-code-review-validator.yml`)
- Trigger configuration (opened, synchronize, reopened)
- Secret management (BEDROCK_BASE_URL, PORTKEY_API_KEY)
- Environment variable wiring for Claude CLI + Portkey
- Artifact retention (90-day violation history)
- Fail-closed policy → crash = REQUEST_CHANGES

## Phase 6: Skill Factory (Meta-Tool)

- Design spec for skill creation agent (`code-review-skill-factory-design.md`)
- Interactive skill builder (create mode + edit mode)
- SKILL.md template with rules, categories, severities, examples
- Reference.md template for extended code examples
- Validation checklist for skill completeness
- Zero-config discovery → sub-agents read skills at runtime

## Phase 7: First Skill — Proof of Concept

- `container-presentational-ts-strictness` skill created
- Rules: no mixed data-fetching/rendering, no `any`, named prop interfaces, explicit return types
- Reference examples added
- Hello-app Next.js test project created as review target

## Phase 8: Deployment & Debugging

- First real PR trigger → model ID issues (short names vs full ARNs)
- Portkey gateway debugging (auth failures, 400 errors)
- CLI output parsing fixes (markdown-fenced JSON handling)
- Verbose logging added for diagnosis
- Secret configuration lessons learned (copy verbatim, never retype)
- Spec updated with deployment lessons

## Phase 9: Validation & Iteration

- End-to-end PR review working
- Violations detected and posted as inline comments
- Incremental mode tested on subsequent pushes
- Code fixed to resolve detected violations
- Local test script for dry-runs without CI

---

## Key Concepts (Presentation Keywords)

- **AI Multi-Agent Pipeline** — divide and conquer with specialized models
- **Fail-Closed** — safety default, crash = block PR
- **Pluggable Skills** — extend without touching infrastructure
- **FULL vs INCREMENTAL** — smart re-review on subsequent pushes
- **Prompt-as-Code** — version-controlled prompt templates
- **Gateway Pattern** — Portkey abstracting Bedrock access
- **Structured Output** — JSON violation schema for machine processing
- **Self-Healing Reviews** — cleanup old comments, dismiss stale reviews
- **Spec-Driven Development** — design doc → plan → implement → debug → iterate
- **Local-First Testing** — dry-run script before CI

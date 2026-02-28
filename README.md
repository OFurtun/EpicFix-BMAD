# EpicFix-BMAD

A post-epic **quality audit and repair** pipeline for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using the [Ralph Wiggum method](https://www.geoffreyhuntley.com/ralph-wiggum).

After a dev agent finishes an epic, EpicFix audits every story's implementation — tests, architecture compliance, code quality, cross-cutting patterns — then generates a repair story that Ralph can execute. The audit complement to [RalphWiggum-BMAD](https://github.com/OFurtun/RalphWiggum-BMAD) (dev execution) and [HomerSimpson-BMAD](https://github.com/OFurtun/HomerSimpson-BMAD) (story creation).

Works with [BMAD-METHOD](https://github.com/OFurtun/BMAD-METHOD) projects out of the box. Also works with any project that has markdown story files and architecture docs.

## Quick Start

```bash
# Clone the installer
git clone https://github.com/OFurtun/EpicFix-BMAD.git /tmp/epicfix-installer

# Install into your project
/tmp/epicfix-installer/install.sh /path/to/your/project

# Audit an epic (from your project directory)
cd /path/to/your/project
/epic-fix 2                     # via Claude Code skill
```

## What It Does

For a completed epic:

1. **Discover** — Find all story files, source files, test files, and relevant architecture shards
2. **Audit** — Spawn parallel subagents, each performing deep semantic analysis on one story (5 checks including deferral awareness)
3. **Synthesize** — Deduplicate, group, and rank all findings by severity
4. **Verify** — Cross-reference findings against decisions register, story deferrals, and framework APIs to eliminate false positives
5. **Triage** — Present verified findings to user for approval (critical+important recommended)
6. **Repair** — Generate a BMAD-format repair story via fresh `claude -p`
7. **Execute** — Optionally chain into Ralph to implement the fixes

```
/epic-fix 2 (Claude Code skill)
    |
    +-- SKILL.md orchestrator          <- Phases 1-2.5 (audit + synthesis + verify + triage)
    |   |
    |   +-- Parallel audit subagents   <- One per story, 5 checks incl. deferral awareness
    |   |   (audit-prompt.md)
    |   |
    |   +-- Verification subagents     <- Cross-ref findings vs deferrals & framework APIs
    |   |   (verification-prompt.md)
    |   |
    |   +-- Synthesis + User triage
    |
    +-- epic-fix.sh                    <- Phases 3-4 (repair story + optional Ralph)
        |
        +-- claude -p (repair)         <- Fresh process, reads TRIAGE.md
        |   (repair-story-prompt.md)
        |
        +-- ralph.sh (optional)        <- Execute the repair story
```

## Architecture

```
                              /epic-fix N
                                    |
                    +-------------------------------+
                    |          SKILL.md              |
                    |       (orchestrator)           |
                    |                               |
                    |  Phase 1: Parallel Audit       |
                    |  Phase 2: Synthesis + Triage   |
                    +---------------+---------------+
                                    |
              +---------------------+---------------------+
              |                     |                     |
        +-----v-----+        +-----v-----+        +-----v-----+
        | Subagent   |        | Subagent   |        | Subagent   |
        | Story 2.1  |        | Story 2.2  |        | Story 2.3  |
        |            |        |            |        |            |
        | Reads:     |        | Reads:     |        | Reads:     |
        |  - Story   |        |  - Story   |        |  - Story   |
        |  - Source   |        |  - Source   |        |  - Source   |
        |  - Tests   |        |  - Tests   |        |  - Tests   |
        |  - Arch    |        |  - Arch    |        |  - Arch    |
        |            |        |            |        |            |
        | 5 checks:  |        | 5 checks:  |        | 5 checks:  |
        |  Test valid |        |  Test valid |        |  Test valid |
        |  Arch compl |        |  Arch compl |        |  Arch compl |
        |  Code qual  |        |  Code qual  |        |  Code qual  |
        |  Cross-cut  |        |  Cross-cut  |        |  Cross-cut  |
        |  Deferrals  |        |  Deferrals  |        |  Deferrals  |
        +-----+-----+        +-----+-----+        +-----+-----+
              |                     |                     |
              +---------------------+---------------------+
                                    |
                    +---------------v---------------+
                    |     Phase 2: Synthesis         |
                    |  Deduplicate + group findings   |
                    +---------------+---------------+
                                    |
                    +---------------v---------------+
                    |   Phase 2.5: Verification      |
                    |                               |
                    |  Cross-ref vs Decisions Reg.   |
                    |  Story-spec deferral check     |
                    |  Framework API verification    |
                    |  MVP appropriateness filter    |
                    +---------------+---------------+
                                    |
                    +---------------v---------------+
                    |     User Triage               |
                    |  Present verified findings     |
                    |  Write TRIAGE.md               |
                    +---------------+---------------+
                                    |
                    +---------------v---------------+
                    |       epic-fix.sh              |
                    |    (Phase 3-4)                 |
                    |                               |
                    |  Fresh claude -p               |
                    |  Reads TRIAGE.md               |
                    |  Writes repair story           |
                    |                               |
                    |  Optional: chain to Ralph      |
                    +-------------------------------+

              +----------- Runtime State -----------+
              |                                     |
              |  PROGRESS.md       FINDINGS.md      |
              |  (audit tracking)  (synthesis)       |
              |  +------------+   +--------------+  |
              |  | Story table |   | All findings |  |
              |  | Phase state |   | Grouped      |  |
              |  | Timestamps  |   | Deduplicated |  |
              |  +------------+   +--------------+  |
              |                                     |
              |  TRIAGE.md         audit-N.M.md     |
              |  (approved)        (per-story raw)   |
              |  +------------+   +--------------+  |
              |  | User picks  |   | JSON findings|  |
              |  | Severity    |   | Raw output   |  |
              |  | Counts      |   | 4 checks     |  |
              |  +------------+   +--------------+  |
              +-------------------------------------+
```

## The 5 Audit Checks

Each subagent performs these checks against one story's implementation:

| Check | What It Catches | Severity |
|-------|----------------|----------|
| **Test Behavioral Validity** | Fake tests (readFileSync, conditional assertions, vacuous expects, empty bodies) | Critical |
| **Architecture Compliance** | DDL mismatches, missing RLS, missing triggers, wrong indexes, FK violations | Critical/Important |
| **Code Quality** | Duplication, hardcoded strings, anti-patterns, dead code, missing error handling | Important |
| **Cross-Cutting Compliance** | i18n gaps, naming violations, import patterns, responsive design | Minor |
| **Deferral Awareness** | Cross-references findings against Decisions Register and story deferrals to mark intentional gaps as "deferred" rather than bugs | Deferred |

## Homer + Ralph + EpicFix Pipeline

The three tools form a complete development pipeline:

```
Homer (SM)                  Ralph (Dev)              EpicFix (QA)
  |                           |                        |
  +-- Create story files ---> +-- Execute stories ---> +-- Audit epic
  |   (backlog -> ready)      |   (ready -> done)      |   (parallel subagents)
  |                           |                        |
  |                           |                        +-- Generate repair story
  |                           |                        |   (fresh claude -p)
  |                           |                        |
  |                           +<-- Execute repair -----+   (optional Ralph chain)
```

## Installation

```bash
./install.sh [project-directory]
```

The interactive installer:
1. Asks which project to install into
2. Detects BMAD (sets defaults automatically) or uses generic defaults
3. Configures stories, architecture, project context, sprint status, and Ralph paths
4. Copies everything into `{project}/.claude/skills/epic-fix/`
5. Generates an `epic-fix.config` with your settings

### What Gets Installed

```
your-project/
+-- .claude/skills/epic-fix/
    |-- SKILL.md                    # Claude Code skill definition (/epic-fix)
    |-- epic-fix.config             # Your project-specific configuration
    +-- scripts/
        |-- epic-fix.sh             # Repair story generator (Phase 3-4)
        |-- audit-prompt.md         # Audit subagent system prompt (5 checks)
        |-- verification-prompt.md  # Verification subagent system prompt (Phase 2.5)
        +-- repair-story-prompt.md  # Repair story generator system prompt
```

### Configuration

| Setting | BMAD Default | Generic Default |
|---------|-------------|-----------------|
| Stories directory | `_bmad-output/implementation-artifacts` | `stories` |
| Architecture docs | `_bmad-output/planning-artifacts/architecture` | `none` |
| Project context | `_bmad-output/planning-artifacts/project-context.md` | `none` |
| Epics / Decisions Register | `_bmad-output/planning-artifacts/epics.md` | `none` |
| Sprint status | `_bmad-output/implementation-artifacts/sprint-status.yaml` | `sprint-status.yaml` |
| Ralph skill dir | `.claude/skills/ralph` | `.claude/skills/ralph` |
| Runtime directory | `_epic-fix` | `_epic-fix` |

Edit `epic-fix.config` anytime to reconfigure, or re-run `install.sh`.

## Usage

```bash
# Audit an epic and generate repair story
/epic-fix 2

# Audit only (no repair story generation)
/epic-fix 2 --dry-run

# Generate repair story but don't auto-launch Ralph
/epic-fix 2 --skip-ralph

# Direct script execution (Phase 3-4 only, after manual triage)
bash .claude/skills/epic-fix/scripts/epic-fix.sh --epic 2 --triage _epic-fix/TRIAGE.md
```

## How It Works

### Phase 1: Parallel Audit

EpicFix spawns one subagent per story (batched in groups of 8). Each subagent:
- Reads the story spec, all source files, all test files, relevant architecture shards, project context, and decisions register
- Performs 5 deep semantic checks (not grep patterns), including deferral awareness
- Outputs structured JSON findings (with `deferred` severity for tracked deferrals)

### Phase 2: Synthesis

The orchestrator:
- Collects all findings from all subagents
- Deduplicates by `file + line + category`
- Separates deferred findings from actionable ones
- Groups by severity and category

### Phase 2.5: Verification

Verification subagents cross-reference each finding against:
- **Decisions Register** — project-level deferrals (D1-D12+)
- **Story-spec deferrals** — "Out of Scope" and "Decisions Applied" sections
- **Cross-story scope** — was this feature actually specified in the story's ACs?
- **Framework APIs** — reads actual type definitions to verify claims about framework limitations
- **MVP appropriateness** — filters scale concerns irrelevant at current usage

Each finding gets a verdict: `confirmed`, `excluded`, `reclassified`, or `incorrect`. This eliminates false positives before presenting to the user.

### User Triage

- Presents verified findings to the user
- User picks: all findings, critical+important (recommended), critical only, or custom selection
- Approved findings go to `TRIAGE.md` with excluded findings documented for traceability

### Phase 3: Repair Story Generation

A fresh `claude -p` process reads `TRIAGE.md` and generates a BMAD-format repair story:
- One AC per logical fix group (max 20)
- Tasks with embedded code/SQL (Ralph has no memory of architecture)
- Ordered by dependency (infra first, fixes, then tests)
- Cross-verification against architecture shards

### Phase 4: Optional Ralph Execution

If Ralph is installed and `--skip-ralph` is not set, EpicFix launches Ralph to execute the repair story automatically.

### Audit Findings Format

Each subagent outputs findings as structured JSON. See `examples/findings-format.json` for the full schema.

```json
{
  "id": "F001",
  "severity": "critical",
  "category": "test-validity",
  "file": "tests/unit/components/layout.test.ts",
  "line": 15,
  "description": "Unit test uses readFileSync instead of rendering component",
  "evidence": "import { readFileSync } from 'fs';",
  "fix_hint": "Replace with @testing-library/svelte render() + screen queries"
}
```

## Prerequisites

EpicFix needs these artifacts to exist in your project:

1. **Story files** — Completed implementation stories in markdown
2. **Architecture docs** (recommended) — For canonical DDL, RLS, and pattern verification
3. **Epics/planning file** (recommended) — For Decisions Register (deliberate deferrals). Dramatically reduces false positives.
4. **Source and test files** — The actual code to audit (discovered from Ralph records or git history)

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI (`claude` command)
- `bash` 4+
- `awk`

## Credits

- **Ralph Wiggum Method**: [Geoffrey Huntley](https://www.geoffreyhuntley.com/ralph-wiggum) (February 2025)
- **Relay Baton Pattern**: [Anand Chowdhary](https://anandchowdhary.com/blog/ralph-wiggum)
- **BMAD Method**: [BMAD-METHOD](https://github.com/OFurtun/BMAD-METHOD)

## License

MIT

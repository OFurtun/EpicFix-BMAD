---
name: epic-fix
description: "Post-epic quality audit and repair. Deep parallel audit per story, synthesis, user triage, repair story generation, optional Ralph launch."
argument-hint: "[epic-number] [--dry-run] [--skip-ralph]"
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Task
---

# Epic-Fix: Post-Epic Quality Audit & Repair

You are the orchestrator for the epic-fix pipeline. You run Phases 1-2 (parallel audit + synthesis + triage) directly, then launch `epic-fix.sh` for Phases 3-4 (repair story generation + optional Ralph execution).

**Key design constraint:** Subagent-parallel deep audit, NOT grep patterns. Each subagent loads full architecture shards + story specs + source files for semantic cross-referencing. Context isolation is mandatory.

## Arguments

- `$ARGUMENTS[0]` — Epic number (required)
- `--dry-run` — Run audit and synthesis but do not generate repair story
- `--skip-ralph` — Generate repair story but do not launch Ralph

## Configuration

Read `epic-fix.config` (in this skill directory) for configured paths. It defines:

| Setting | Description |
|---------|-------------|
| `STORIES_DIR` | Story files directory |
| `ARCHITECTURE_DIR` | Architecture documentation directory |
| `PROJECT_CONTEXT` | Project context/coding standards file |
| `SPRINT_STATUS` | Sprint status YAML file |
| `RALPH_SKILL_DIR` | Ralph skill directory (for optional chaining) |
| `RUNTIME_DIR` | Runtime state directory |
| `MAX_TURNS` | Max turns for repair story generation |

Use these paths throughout. Default BMAD paths are used if no config exists.

## Procedure

### Step 1: Parse Arguments

Extract from `$ARGUMENTS`:
- Epic number (required — halt if missing)
- `--dry-run` flag
- `--skip-ralph` flag

### Step 2: Validate Prerequisites

Check these exist. HALT with clear error if missing:

1. **Story files**: Glob `{STORIES_DIR}/{epic}-*-*.md`
   - Exclude any existing `*-retroactive-quality-fixes.md` files from the audit scope
   - If no story files found: "No story files found for Epic {N}."
2. **Architecture index**: `{ARCHITECTURE_DIR}/index.md`
3. **Scripts**: `.claude/skills/epic-fix/scripts/epic-fix.sh` and `audit-prompt.md` and `repair-story-prompt.md`
4. **Ralph records** (optional): Glob `_ralph/story-{epic}.*-record.md`
   - If missing, warn: "No Ralph records found. Will use git log for file discovery."

### Step 3: Discover Scope

For each story file (excluding repair stories):

1. **Read the story file** to get its title, file list, and modified files
2. **Check for Ralph record** at `_ralph/story-{epic}.{N}-record.md`
   - If exists, read it for the file list (source files touched by Ralph)
   - If missing, discover files from git:
     ```bash
     git log --oneline --all --grep="Story {epic}.{N}" | head -5
     ```
     Then for each commit hash:
     ```bash
     git diff-tree --name-only -r {hash}
     ```
3. **Read architecture index.md** to map story content to relevant shards
   - Infrastructure stories → `infrastructure.md`
   - Entity/data stories → `entity-model.md`
   - All stories → `cross-cutting.md` (always included)
4. **Build per-story audit context** — collect:
   - Story file path
   - Source file paths (from ralph record or git)
   - Test file paths (glob `tests/unit/**` and `tests/e2e/**` for files matching story components)
   - Relevant architecture shard paths

Display the scope summary:
```
Epic {N} Audit Scope:
  Story {N}.1: {title} — {X} source files, {Y} test files, shards: [entity-model, cross-cutting]
  Story {N}.2: {title} — {X} source files, {Y} test files, shards: [infrastructure, cross-cutting]
  ...
Total: {count} stories, {total_source} source files, {total_test} test files
```

### Step 4: Initialize Runtime

1. Create runtime directory (from config)
2. Add runtime directory to `.gitignore` if not already present
3. Create `{RUNTIME_DIR}/PROGRESS.md`:
```markdown
# Epic-Fix Progress — Epic {N}

## Run Info
- Epic: {N}
- Started: {timestamp}
- Stories: {count}

## Phase 1: Parallel Audit
| Story | Status | Findings | Critical | Important | Minor |
|-------|--------|----------|----------|-----------|-------|
| {N}.1 | pending | — | — | — | — |
...
```

### Step 5: Phase 1 — Parallel Audit

For each story, spawn a Task subagent (`subagent_type: "general-purpose"`) with a prompt that includes:

1. The content of `audit-prompt.md` (read it and include inline)
2. Instructions to read these files:
   - The story spec file path
   - Each source file path
   - Each test file path
   - Each architecture shard path
   - Project context file (from config)
3. The story key for the findings JSON output

**Batching**: If there are more than 8 stories, batch into groups of 8. Wait for each batch to complete before starting the next.

**Subagent prompt template**:
```
You are an audit agent. Follow the instructions in the audit prompt below.

## Audit Prompt
{content of audit-prompt.md}

## Story to Audit
Story key: {N.M}
Story file: {path} — READ THIS FILE
Source files: {paths} — READ EACH FILE
Test files: {paths} — READ EACH FILE
Architecture shards: {paths} — READ EACH FILE
Project context: {PROJECT_CONTEXT} — READ THIS FILE

Perform all 4 audit checks. Output the JSON findings block.
```

As each subagent completes:
- Parse the JSON findings block from its output
- Save raw output to `{RUNTIME_DIR}/audit-{story_key}.md`
- Update PROGRESS.md with finding counts
- If subagent fails (no JSON block), mark as `audit-failed` and save raw output

### Step 6: Phase 2 — Synthesis

After all subagents complete:

1. **Collect** all findings from all story audits
2. **Deduplicate** by `file + line + category` — if the same issue is flagged by multiple story audits, keep one finding with all story references
3. **Group** by severity (critical → important → minor) and category
4. **Count** totals and present synthesis report:

```
Epic {N} Audit Synthesis
========================

Critical ({count}):
  [C1] test-validity: {description} — {file}:{line}
  ...

Important ({count}):
  [I1] code-quality: {description} — {file}:{line}
  ...

Minor ({count}):
  [M1] cross-cutting: {description} — {file}:{line}
  ...

Total: {total} findings ({critical} critical, {important} important, {minor} minor)
Stories audited: {count} ({failed} audit failures)
```

Write the full synthesis to `{RUNTIME_DIR}/FINDINGS.md`.

### Step 7: User Triage

Present findings to the user and ask which to include in the repair story.

Use AskUserQuestion with options:
- **All findings** — Include everything
- **Critical + Important** — Skip minor findings (Recommended)
- **Critical only** — Minimum viable fix
- **Custom selection** — "I'll specify which to include"

If user picks "Custom selection", list each finding by ID and let them specify which to include/exclude.

**AC count warning**: If approved findings would likely produce >20 ACs, warn the user.

Write approved findings to `{RUNTIME_DIR}/TRIAGE.md`.

**Zero findings**: If the audit found zero issues, report "Clean audit — no quality issues found" and exit without creating a repair story.

### Step 8: Phase 3-4 — Launch Bash

Unless `--dry-run` was specified, launch the repair story generator:

```bash
bash .claude/skills/epic-fix/scripts/epic-fix.sh \
  --epic "$EPIC_NUM" \
  --triage "{RUNTIME_DIR}/TRIAGE.md" \
  --repair-prompt ".claude/skills/epic-fix/scripts/repair-story-prompt.md"
```

Pass `--skip-ralph` if the user specified it.

Run this as a foreground Bash command — the user should see progress.

### Step 9: Report

After epic-fix.sh completes, report:
- Repair story file path
- Number of ACs and tasks in the generated story
- Whether Ralph was launched
- Path to `{RUNTIME_DIR}/PROGRESS.md` for full audit trail

## Edge Cases

### Missing Ralph Records
Fall back to git log for file discovery. Warn the user but continue.

### Subagent Failure
If a subagent returns no parseable JSON:
- Save the raw output to `{RUNTIME_DIR}/audit-{story_key}.md`
- Mark as `audit-failed` in PROGRESS.md
- Continue with other stories
- Report failures in the synthesis

### Zero Findings
Report clean audit. Do NOT generate a repair story. Exit cleanly.

### Existing Repair Story File
If a repair story already exists for this epic, increment the story number to avoid collision. epic-fix.sh handles this.

### >20 ACs
Warn during triage. Let user decide whether to proceed, group more aggressively, or split.

## Notes

- **No git operations.** This skill reads git history but does not commit or branch.
- **Runtime directory** is ephemeral audit state. It's gitignored.
- **Audit subagents are READ-ONLY.** They analyze files but do not modify anything.
- **Repair story generation uses a fresh `claude -p`** for context isolation.
- **Ralph chaining is optional.** User can always run Ralph manually later.

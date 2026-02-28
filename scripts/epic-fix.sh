#!/usr/bin/env bash
set -euo pipefail

# Allow nested claude -p processes when launched from within a Claude Code session
unset CLAUDECODE 2>/dev/null || true

# Epic-Fix Repair Story Generator (Phase 3-4)
# Takes triaged findings, generates a repair story via fresh claude -p,
# optionally chains into ralph.sh for execution.

# ─── Find config (next to this script's parent) ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="${EPICFIX_CONFIG:-$SKILL_DIR/epic-fix.config}"

# ─── Defaults ───
EPIC=""
TRIAGE_FILE=""
REPAIR_PROMPT="$SCRIPT_DIR/repair-story-prompt.md"
STORIES_DIR="_bmad-output/implementation-artifacts"
SPRINT_STATUS="_bmad-output/implementation-artifacts/sprint-status.yaml"
ARCHITECTURE_DIR="_bmad-output/planning-artifacts/architecture"
EXEMPLAR=""
RUNTIME_DIR="_epic-fix"
RALPH_SKILL_DIR=""
MAX_TURNS=200
SKIP_RALPH=false
DRY_RUN=false

# ─── Load config if it exists ───
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# ─── Help ───
show_help() {
  cat <<'HELP'
Epic-Fix Repair Story Generator (Phase 3-4)
============================================

Takes triaged audit findings and generates a BMAD repair story.
Optionally chains into ralph.sh for automated execution.

USAGE:
  epic-fix.sh --epic <N> --triage <path> [OPTIONS]

REQUIRED:
  --epic <N>              Epic number to generate repair story for
  --triage <path>         Path to TRIAGE.md (approved findings)

OPTIONS:
  --repair-prompt <path>  Repair story system prompt (default: auto-detected)
  --exemplar <path>       Repair story exemplar (default: auto-detected)
  --max-turns <N>         Max turns for story generation (default: 200)
  --skip-ralph            Generate story but do not launch Ralph
  --dry-run               Show what would execute without running
  --help                  Show this help

EXAMPLES:
  epic-fix.sh --epic 2 --triage _epic-fix/TRIAGE.md
  epic-fix.sh --epic 2 --triage _epic-fix/TRIAGE.md --skip-ralph
  epic-fix.sh --epic 2 --triage _epic-fix/TRIAGE.md --dry-run

FILES:
  Input:  _epic-fix/TRIAGE.md            Approved findings from Phase 2
  Output: {STORIES_DIR}/{epic}-{N}-retroactive-quality-fixes.md
HELP
  exit 0
}

# ─── Parse arguments ───
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) show_help ;;
    --epic) EPIC="$2"; shift 2 ;;
    --triage) TRIAGE_FILE="$2"; shift 2 ;;
    --repair-prompt) REPAIR_PROMPT="$2"; shift 2 ;;
    --exemplar) EXEMPLAR="$2"; shift 2 ;;
    --max-turns) MAX_TURNS="$2"; shift 2 ;;
    --skip-ralph) SKIP_RALPH=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "ERROR: Unknown option: $1"; echo "Use --help for usage."; exit 1 ;;
  esac
done

# ─── Validate required args ───
if [ -z "$EPIC" ]; then
  echo "ERROR: --epic is required"
  echo "Use --help for usage."
  exit 1
fi

if [ -z "$TRIAGE_FILE" ]; then
  echo "ERROR: --triage is required"
  echo "Use --help for usage."
  exit 1
fi

# ─── Validate prerequisites ───
if [ ! -f "$TRIAGE_FILE" ]; then
  echo "ERROR: Triage file not found: $TRIAGE_FILE"
  exit 1
fi

if [ ! -f "$REPAIR_PROMPT" ]; then
  echo "ERROR: Repair prompt not found: $REPAIR_PROMPT"
  exit 1
fi

if [ ! -d "$ARCHITECTURE_DIR" ]; then
  echo "ERROR: Architecture directory not found: $ARCHITECTURE_DIR"
  exit 1
fi

if [ -n "$EXEMPLAR" ] && [ ! -f "$EXEMPLAR" ]; then
  echo "WARNING: Exemplar not found: $EXEMPLAR"
  echo "  Repair story generation will proceed without format reference."
  echo ""
fi

# ─── Ensure runtime dir exists ───
mkdir -p "$RUNTIME_DIR"

# ─── Helpers ───
timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

update_sprint_status() {
  local story_slug="$1" new_status="$2"
  if [ ! -f "$SPRINT_STATUS" ]; then return; fi
  local pattern="  ${story_slug}:"
  local tmpfile
  tmpfile=$(mktemp)
  awk -v pat="$pattern" -v stat="$new_status" '
    index($0, pat) == 1 { match($0, /: /); print substr($0, 1, RSTART + 1) stat; next }
    { print }
  ' "$SPRINT_STATUS" > "$tmpfile" && mv "$tmpfile" "$SPRINT_STATUS"
}

add_sprint_status_entry() {
  local epic_num="$1" story_slug="$2" status="$3"
  if [ ! -f "$SPRINT_STATUS" ]; then return; fi
  local epic_pattern="  epic-${epic_num}:"
  # Check if entry already exists
  if grep -q "  ${story_slug}:" "$SPRINT_STATUS" 2>/dev/null; then
    update_sprint_status "$story_slug" "$status"
    return
  fi
  # Add after the last story in this epic (before next epic or end of stories section)
  local tmpfile
  tmpfile=$(mktemp)
  awk -v epic_pat="$epic_pattern" -v slug="$story_slug" -v stat="$status" '
    BEGIN { found_epic = 0; last_story_line = 0 }
    index($0, epic_pat) == 1 { found_epic = 1 }
    found_epic && /^  [0-9]+-[0-9]+/ { last_story_line = NR }
    found_epic && (/^  epic-/ || /^[^ ]/) && last_story_line > 0 && NR > last_story_line {
      print "  " slug ": " stat
      found_epic = 0
      last_story_line = 0
    }
    { print }
    END {
      if (found_epic && last_story_line > 0) {
        print "  " slug ": " stat
      }
    }
  ' "$SPRINT_STATUS" > "$tmpfile" && mv "$tmpfile" "$SPRINT_STATUS"
}

# ─── Determine repair story number ───
# Find the highest story number for this epic
HIGHEST_NUM=0
for f in "$STORIES_DIR"/"$EPIC"-*-*.md; do
  [ -f "$f" ] || continue
  BASENAME=$(basename "$f" .md)
  STORY_NUM=$(echo "$BASENAME" | cut -d'-' -f2)
  # Strip letter suffixes (e.g., 9a -> 9)
  NUMERIC_PART=$(echo "$STORY_NUM" | sed 's/[a-z]*$//')
  if [ "$NUMERIC_PART" -gt "$HIGHEST_NUM" ] 2>/dev/null; then
    HIGHEST_NUM="$NUMERIC_PART"
  fi
done

REPAIR_NUM=$((HIGHEST_NUM + 1))
REPAIR_SLUG="${EPIC}-${REPAIR_NUM}-retroactive-quality-fixes"
REPAIR_FILE="$STORIES_DIR/${REPAIR_SLUG}.md"
REPAIR_KEY="${EPIC}.${REPAIR_NUM}"

# Check for collision (shouldn't happen but safety)
if [ -f "$REPAIR_FILE" ]; then
  REPAIR_NUM=$((REPAIR_NUM + 1))
  REPAIR_SLUG="${EPIC}-${REPAIR_NUM}-retroactive-quality-fixes"
  REPAIR_FILE="$STORIES_DIR/${REPAIR_SLUG}.md"
  REPAIR_KEY="${EPIC}.${REPAIR_NUM}"
fi

# ─── Collect architecture shard list ───
ARCH_SHARDS=""
if [ -f "$ARCHITECTURE_DIR/index.md" ]; then
  ARCH_SHARDS="$ARCHITECTURE_DIR/index.md"
fi
for shard in entity-model cross-cutting infrastructure; do
  if [ -f "$ARCHITECTURE_DIR/${shard}.md" ]; then
    ARCH_SHARDS="$ARCH_SHARDS $ARCHITECTURE_DIR/${shard}.md"
  fi
done

echo ""
echo "================================================================"
echo "  Epic-Fix Repair Story Generator — Epic $EPIC"
echo "================================================================"
echo "  Triage:       $TRIAGE_FILE"
echo "  Repair story: $REPAIR_FILE"
echo "  Story key:    $REPAIR_KEY"
if [ -n "$EXEMPLAR" ]; then
echo "  Exemplar:     $EXEMPLAR"
fi
echo "  Max turns:    $MAX_TURNS"
echo "  Skip Ralph:   $SKIP_RALPH"
echo "  Started:      $(timestamp)"
echo "================================================================"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "  [DRY RUN] Would generate repair story: $REPAIR_FILE"
  echo "  [DRY RUN] Using triage: $TRIAGE_FILE"
  echo "  [DRY RUN] Architecture shards: $ARCH_SHARDS"
  [ "$SKIP_RALPH" = false ] && echo "  [DRY RUN] Would chain into ralph.sh --start-from $REPAIR_KEY"
  exit 0
fi

# ─── Build static context ───
STATIC_CONTEXT="$(cat "$REPAIR_PROMPT")"

# ─── Build user prompt ───
USER_PROMPT="## Repair Story Generation

### Epic
$EPIC

### Repair Story Key
$REPAIR_KEY

### Repair Story Slug
$REPAIR_SLUG

### Output File
$REPAIR_FILE

### Triage File (approved findings)
Read this file: $TRIAGE_FILE"

if [ -n "$EXEMPLAR" ] && [ -f "$EXEMPLAR" ]; then
USER_PROMPT="$USER_PROMPT

### Exemplar (format reference)
Read this file: $EXEMPLAR"
fi

USER_PROMPT="$USER_PROMPT

### Architecture Shards (read for canonical DDL/RLS/triggers)
$(for shard in $ARCH_SHARDS; do echo "- $shard"; done)

### Stories Directory
$STORIES_DIR

### Migrations Directory
supabase/migrations/"

# ─── Execute: fresh claude -p ───
echo "  Launching repair story generator..."
GEN_START=$(date +%s)

OUTPUT=$(env -u CLAUDECODE claude -p "$USER_PROMPT" \
  --append-system-prompt "$STATIC_CONTEXT" \
  --max-turns "$MAX_TURNS" \
  --allowedTools "Read,Write,Edit,Grep,Glob,Bash" \
  --output-format text \
  2>&1) || true

GEN_END=$(date +%s)
GEN_DURATION=$(( GEN_END - GEN_START ))

# ─── Parse completion signal ───
if echo "$OUTPUT" | grep -q "<promise>REPAIR-STORY-CREATED</promise>"; then
  echo "  Repair story CREATED (${GEN_DURATION}s)"
  echo "  File: $REPAIR_FILE"

  # Update sprint-status.yaml
  add_sprint_status_entry "$EPIC" "$REPAIR_SLUG" "ready-for-dev"
  echo "  Sprint status updated: $REPAIR_SLUG -> ready-for-dev"

  # Update PROGRESS.md
  if [ -f "$RUNTIME_DIR/PROGRESS.md" ]; then
    {
      echo ""
      echo "## Phase 3: Repair Story"
      echo "- Generated: $(timestamp)"
      echo "- Duration: ${GEN_DURATION}s"
      echo "- File: $REPAIR_FILE"
      echo "- Story key: $REPAIR_KEY"
    } >> "$RUNTIME_DIR/PROGRESS.md"
  fi

  # ─── Phase 4: Optional Ralph launch ───
  if [ "$SKIP_RALPH" = false ]; then
    RALPH_SCRIPT=""
    # Check configured Ralph skill directory
    if [ -n "$RALPH_SKILL_DIR" ] && [ -f "$RALPH_SKILL_DIR/scripts/ralph.sh" ]; then
      RALPH_SCRIPT="$RALPH_SKILL_DIR/scripts/ralph.sh"
    # Check default sibling location
    elif [ -f "$(dirname "$SKILL_DIR")/ralph/scripts/ralph.sh" ]; then
      RALPH_SCRIPT="$(dirname "$SKILL_DIR")/ralph/scripts/ralph.sh"
    fi

    if [ -n "$RALPH_SCRIPT" ]; then
      echo ""
      echo "================================================================"
      echo "  Chaining into Ralph — executing repair story $REPAIR_KEY"
      echo "================================================================"
      echo ""
      bash "$RALPH_SCRIPT" --epic "$EPIC" --start-from "$REPAIR_KEY"
    else
      echo ""
      echo "  WARNING: ralph.sh not found"
      echo "  Run manually: /ralph $EPIC --start-from $REPAIR_KEY"
    fi
  else
    echo ""
    echo "  --skip-ralph specified. Run manually:"
    echo "  /ralph $EPIC --start-from $REPAIR_KEY"
  fi

elif echo "$OUTPUT" | grep -q "<promise>REPAIR-STORY-BLOCKED:"; then
  BLOCK_REASON=$(echo "$OUTPUT" | grep -o "<promise>REPAIR-STORY-BLOCKED:[^<]*</promise>" | sed "s/<promise>REPAIR-STORY-BLOCKED://;s/<\/promise>//")
  echo "  Repair story BLOCKED: $BLOCK_REASON (${GEN_DURATION}s)"

  if [ -f "$RUNTIME_DIR/PROGRESS.md" ]; then
    {
      echo ""
      echo "## Phase 3: Repair Story — BLOCKED"
      echo "- Blocked: $(timestamp)"
      echo "- Duration: ${GEN_DURATION}s"
      echo "- Reason: $BLOCK_REASON"
    } >> "$RUNTIME_DIR/PROGRESS.md"
  fi

  echo "$OUTPUT" > "$RUNTIME_DIR/generator-debug.txt"
  exit 1

else
  echo "  Repair story generation FAILED — no completion signal (${GEN_DURATION}s)"
  echo "  Debug output saved to $RUNTIME_DIR/generator-debug.txt"
  echo "$OUTPUT" > "$RUNTIME_DIR/generator-debug.txt"

  if [ -f "$RUNTIME_DIR/PROGRESS.md" ]; then
    {
      echo ""
      echo "## Phase 3: Repair Story — FAILED"
      echo "- Failed: $(timestamp)"
      echo "- Duration: ${GEN_DURATION}s"
      echo "- Reason: No completion signal"
    } >> "$RUNTIME_DIR/PROGRESS.md"
  fi

  exit 1
fi

echo ""
echo "================================================================"
echo "  Epic-Fix — COMPLETE"
echo "  Repair story: $REPAIR_FILE"
echo "  Finished: $(timestamp)"
echo "================================================================"

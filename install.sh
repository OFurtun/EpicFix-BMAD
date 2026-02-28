#!/usr/bin/env bash
set -euo pipefail

# EpicFix-BMAD Installer
# Installs Epic-Fix into a target project's .claude/skills/epic-fix/

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "═══════════════════════════════════════════════════"
echo "  EpicFix-BMAD Installer"
echo "═══════════════════════════════════════════════════"
echo ""

# ─── Step 1: Pick target project ───
echo "── Target Project ─────────────────────────────"
echo ""

if [ -n "${1:-}" ]; then
  TARGET_DIR="$1"
else
  read -rp "  Project directory to install into: " TARGET_DIR
fi

# Expand ~ and resolve path
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: Directory does not exist: $TARGET_DIR"
  exit 1
}

if [ ! -d "$TARGET_DIR/.git" ]; then
  echo "WARNING: $TARGET_DIR is not a git repository."
  read -rp "  Continue anyway? [y/N]: " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

echo "  Installing into: $TARGET_DIR"
echo ""

# ─── Step 2: Detect BMAD ───
BMAD_DETECTED=false
if [ -d "$TARGET_DIR/_bmad-output/implementation-artifacts" ] || [ -d "$TARGET_DIR/_bmad-output/planning-artifacts" ]; then
  BMAD_DETECTED=true
  echo "  Detected: BMAD project structure"
elif [ -d "$TARGET_DIR/_bmad" ] || [ -d "$TARGET_DIR/_bmad-project" ]; then
  BMAD_DETECTED=true
  echo "  Detected: BMAD installation (no output yet)"
else
  echo "  No BMAD installation detected — using generic defaults"
fi
echo ""

# ─── Helper ───
ask() {
  local prompt="$1"
  local default="$2"
  local result
  read -rp "  $prompt [$default]: " result
  echo "${result:-$default}"
}

# ─── Step 3: Configure paths ───
echo "── Story Files ──────────────────────────────────"
echo "  Directory containing implementation story files."
echo "  Epic-Fix audits these and generates repair stories here."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  STORIES_DIR=$(ask "Stories directory (relative to project root)" "_bmad-output/implementation-artifacts")
else
  STORIES_DIR=$(ask "Stories directory (relative to project root)" "stories")
fi
echo ""

echo "── Architecture Docs ────────────────────────────"
echo "  Directory containing architecture documentation."
echo "  Audit agents read these for canonical schemas, DDL, and patterns."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  ARCHITECTURE_DIR=$(ask "Architecture docs directory" "_bmad-output/planning-artifacts/architecture")
else
  ARCHITECTURE_DIR=$(ask "Architecture docs directory (or 'none')" "none")
fi
echo ""

echo "── Project Context ──────────────────────────────"
echo "  A markdown file with coding standards, naming conventions."
echo "  Audit agents read this for cross-cutting compliance checks."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  PROJECT_CONTEXT=$(ask "Project context file (or 'none')" "_bmad-output/planning-artifacts/project-context.md")
else
  PROJECT_CONTEXT=$(ask "Project context file (or 'none')" "none")
fi
echo ""

echo "── Sprint Status ────────────────────────────────"
echo "  A YAML file tracking story statuses."
echo "  Epic-Fix adds repair stories here as ready-for-dev."
echo ""
if [ "$BMAD_DETECTED" = true ]; then
  SPRINT_STATUS=$(ask "Sprint status file (or 'none')" "_bmad-output/implementation-artifacts/sprint-status.yaml")
else
  SPRINT_STATUS=$(ask "Sprint status file (or 'none')" "sprint-status.yaml")
fi
echo ""

echo "── Ralph Skill ────────────────────────────────"
echo "  Path to Ralph's skill directory (for optional Ralph chaining)."
echo "  After generating a repair story, epic-fix can launch Ralph to execute it."
echo ""
RALPH_SKILL_DIR=$(ask "Ralph skill directory (or 'none')" ".claude/skills/ralph")
echo ""

echo "── Runtime Directory ────────────────────────────"
echo "  Where Epic-Fix stores audit results, findings, and triage."
echo "  Auto-added to .gitignore."
echo ""
RUNTIME_DIR=$(ask "Runtime directory" "_epic-fix")
echo ""

echo "── Tuning ───────────────────────────────────────"
echo ""
MAX_TURNS=$(ask "Max turns for repair story generation (claude -p)" "200")
echo ""

# ─── Step 4: Install files ───
SKILL_DIR="$TARGET_DIR/.claude/skills/epic-fix"
mkdir -p "$SKILL_DIR/scripts"

echo "── Installing ─────────────────────────────────"

# Copy scripts and prompts
cp "$INSTALLER_DIR/scripts/epic-fix.sh" "$SKILL_DIR/scripts/epic-fix.sh"
cp "$INSTALLER_DIR/prompts/audit-prompt.md" "$SKILL_DIR/scripts/audit-prompt.md"
cp "$INSTALLER_DIR/prompts/repair-story-prompt.md" "$SKILL_DIR/scripts/repair-story-prompt.md"
cp "$INSTALLER_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
chmod +x "$SKILL_DIR/scripts/epic-fix.sh"

echo "  Copied: SKILL.md"
echo "  Copied: scripts/epic-fix.sh"
echo "  Copied: scripts/audit-prompt.md"
echo "  Copied: scripts/repair-story-prompt.md"

# ─── Step 5: Write config into the skill directory ───
cat > "$SKILL_DIR/epic-fix.config" <<CONF
# EpicFix-BMAD Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Project: $(basename "$TARGET_DIR")

# Story files
STORIES_DIR="$STORIES_DIR"

# Architecture
ARCHITECTURE_DIR="$ARCHITECTURE_DIR"

# Context
PROJECT_CONTEXT="$PROJECT_CONTEXT"

# Sprint status
SPRINT_STATUS="$SPRINT_STATUS"

# Ralph (for optional chaining)
RALPH_SKILL_DIR="$RALPH_SKILL_DIR"

# Runtime
RUNTIME_DIR="$RUNTIME_DIR"

# Tuning
MAX_TURNS=$MAX_TURNS
CONF

echo "  Written: epic-fix.config"

echo ""

# ─── Step 6: Ensure runtime dir gitignored ───
GITIGNORE="$TARGET_DIR/.gitignore"
if [ ! -f "$GITIGNORE" ] || ! grep -q "^${RUNTIME_DIR}/" "$GITIGNORE" 2>/dev/null; then
  echo "${RUNTIME_DIR}/" >> "$GITIGNORE"
  echo "  Added ${RUNTIME_DIR}/ to .gitignore"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Installation complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  Installed to: $SKILL_DIR/"
echo ""
echo "  Files:"
echo "    $SKILL_DIR/SKILL.md"
echo "    $SKILL_DIR/epic-fix.config"
echo "    $SKILL_DIR/scripts/epic-fix.sh"
echo "    $SKILL_DIR/scripts/audit-prompt.md"
echo "    $SKILL_DIR/scripts/repair-story-prompt.md"
echo ""
echo "  Usage:"
echo "    cd $TARGET_DIR"
echo "    /epic-fix 2                    # via Claude Code skill"
echo "    bash $SKILL_DIR/scripts/epic-fix.sh --epic 2 --triage $RUNTIME_DIR/TRIAGE.md   # direct (Phase 3-4 only)"
echo ""
echo "  To reconfigure: re-run this installer or edit $SKILL_DIR/epic-fix.config"
echo "═══════════════════════════════════════════════════"

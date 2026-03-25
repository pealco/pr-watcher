#!/usr/bin/env bash
# install.sh — set up pr-watcher as a launchd daemon on macOS
#
# What this does:
#   1. Validates prerequisites (gh, claude, git)
#   2. Creates pr-watcher.conf from the example (if it doesn't exist)
#   3. Installs Claude Code skills (symlinks to ~/.claude/skills/)
#   4. Generates and loads a launchd plist
#   5. Makes scripts executable

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="$INSTALL_DIR/pr-watcher.conf"
PLIST_NAME="com.pr-watcher"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_FILE="$PLIST_DIR/$PLIST_NAME.plist"

echo "pr-watcher installer"
echo "===================="
echo

# --- Prerequisites ---
missing=()
command -v gh >/dev/null 2>&1 || missing+=("gh (GitHub CLI)")
command -v claude >/dev/null 2>&1 || missing+=("claude (Claude Code)")
command -v git >/dev/null 2>&1 || missing+=("git")

if (( ${#missing[@]} > 0 )); then
    echo "ERROR: missing required tools:"
    for tool in "${missing[@]}"; do
        echo "  - $tool"
    done
    echo
    echo "Install them and re-run this script."
    exit 1
fi
echo "[ok] prerequisites found"

# --- Config ---
if [[ ! -f "$CONF_FILE" ]]; then
    cp "$INSTALL_DIR/pr-watcher.conf.example" "$CONF_FILE"
    echo
    echo "Created $CONF_FILE from example."
    echo "Edit it now to set REPO and REPO_DIR, then re-run this script."
    exit 0
fi

source "$CONF_FILE"
if [[ -z "${REPO:-}" ]] || [[ -z "${REPO_DIR:-}" ]]; then
    echo "ERROR: REPO and REPO_DIR must be set in $CONF_FILE"
    exit 1
fi
echo "[ok] config loaded (repo=$REPO)"

# --- Make scripts executable ---
chmod +x "$INSTALL_DIR"/bin/*.sh
echo "[ok] scripts marked executable"

# --- Install skills ---
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"

for skill_dir in "$INSTALL_DIR"/skills/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name=$(basename "$skill_dir")
    target="$SKILLS_DIR/$skill_name"
    if [[ -L "$target" ]] || [[ -d "$target" ]]; then
        rm -rf "$target"
    fi
    ln -s "$skill_dir" "$target"
    echo "[ok] installed skill: $skill_name"
done

# Handle flat skill files (skill.md not in subdirectory)
for skill_file in "$INSTALL_DIR"/skills/*.md; do
    [[ -f "$skill_file" ]] || continue
    skill_name=$(basename "$skill_file" .md)
    target_dir="$SKILLS_DIR/$skill_name"
    mkdir -p "$target_dir"
    ln -sf "$skill_file" "$target_dir/skill.md"
    echo "[ok] installed skill: $skill_name"
done

# --- Generate launchd plist ---
mkdir -p "$PLIST_DIR"

sed \
    -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    -e "s|__REPO_DIR__|$REPO_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    "$INSTALL_DIR/templates/com.pr-watcher.plist" > "$PLIST_FILE"

echo "[ok] wrote $PLIST_FILE"

# --- Load the daemon ---
launchctl bootout "gui/$(id -u)" "$PLIST_FILE" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE"

echo "[ok] daemon loaded and running"
echo
echo "Done! pr-watcher is now polling $REPO every ${POLL_INTERVAL:-60}s."
echo
echo "Useful commands:"
echo "  tail -f ~/.pr-watcher.log          # watch the log"
echo "  launchctl bootout gui/\$(id -u) $PLIST_FILE   # stop"
echo "  launchctl bootstrap gui/\$(id -u) $PLIST_FILE # start"

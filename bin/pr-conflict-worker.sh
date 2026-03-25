#!/usr/bin/env bash
# pr-conflict-worker.sh — resolves merge conflicts on a PR using Claude Code
#
# Called by pr-watcher.sh for reviewed PRs that have merge conflicts.
#
# Usage: pr-conflict-worker.sh <pr_number> <branch>

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../pr-watcher.conf"

pr_number="$1"
branch="$2"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [conflict:$pr_number] $*" >> "$LOG_FILE"
}

worktree_dir="$REPO_DIR/.worktrees/pr-conflict-$pr_number"

cleanup() {
    gh pr edit "$pr_number" --repo "$REPO" --remove-label "deconflicting" 2>/dev/null || true
    timeout 10 git -C "$REPO_DIR" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
    rm -f "$STATE_DIR/$pr_number.conflict-fix.pid"
    log "cleaned up"
}

log "starting (branch=$branch)"

git -C "$REPO_DIR" fetch origin main "$branch" 2>&1 || true
if ! git -C "$REPO_DIR" worktree add --detach "$worktree_dir" "origin/$branch" 2>&1; then
    log "ERROR — failed to create worktree"
    rm -f "$STATE_DIR/$pr_number.conflict-fix.pid"
    exit 1
fi

trap cleanup EXIT

log "created worktree at $worktree_dir"

gh pr edit "$pr_number" --repo "$REPO" --add-label "deconflicting" 2>&1 || true
log "labeled 'deconflicting'"

cd "$worktree_dir" || { log "ERROR — cd to worktree failed"; exit 1; }

log "launching claude to fix merge conflicts..."
"$CLAUDE_BIN" \
    -p "This PR (#$pr_number, branch $branch) has merge conflicts with main. Rebase this branch onto origin/main and resolve all merge conflicts. Keep the intent of the PR's changes while incorporating main's updates. After resolving, force-push the result to the $branch branch." \
    --permission-mode bypassPermissions \
    --model "$REVIEW_MODEL" \
    --no-session-persistence \
    2>&1
fix_exit=$?

if (( fix_exit == 0 )); then
    log "conflict fix completed successfully"
else
    log "conflict fix FAILED (exit $fix_exit)"
fi

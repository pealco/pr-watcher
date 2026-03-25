#!/usr/bin/env bash
# pr-ci-fix-worker.sh — fixes CI failures on a PR using Claude Code
#
# Called by pr-watcher.sh for reviewed PRs with failing CI checks.
#
# Usage: pr-ci-fix-worker.sh <pr_number> <branch>

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../pr-watcher.conf"

pr_number="$1"
branch="$2"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [ci-fix:$pr_number] $*" >> "$LOG_FILE"
}

worktree_dir="$REPO_DIR/.worktrees/pr-ci-fix-$pr_number"

cleanup() {
    gh pr edit "$pr_number" --repo "$REPO" --remove-label "fixing-ci" 2>/dev/null || true
    timeout 10 git -C "$REPO_DIR" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
    rm -f "$STATE_DIR/$pr_number.ci-fix.pid"
    log "cleaned up"
}

log "starting (branch=$branch)"

failed_checks=$(gh pr view "$pr_number" --repo "$REPO" --json statusCheckRollup \
    --jq '[.statusCheckRollup[] | select(.status == "COMPLETED" and .conclusion == "FAILURE") | .name] | join(", ")' \
    2>&1) || failed_checks="unknown"
log "failing checks: $failed_checks"

git -C "$REPO_DIR" fetch origin "$branch" 2>&1 || true
if ! git -C "$REPO_DIR" worktree add --detach "$worktree_dir" "origin/$branch" 2>&1; then
    log "ERROR — failed to create worktree"
    rm -f "$STATE_DIR/$pr_number.ci-fix.pid"
    exit 1
fi

trap cleanup EXIT

log "created worktree at $worktree_dir"

gh pr edit "$pr_number" --repo "$REPO" --add-label "fixing-ci" 2>&1 || true
log "labeled 'fixing-ci'"

cd "$worktree_dir" || { log "ERROR — cd to worktree failed"; exit 1; }

log "launching claude to fix CI failures..."
"$CLAUDE_BIN" \
    -p "PR #$pr_number (branch $branch) has failing CI checks: $failed_checks. Look at the CI logs with \`gh run view\` to understand the failures, fix the issues, commit the fixes, and push to the $branch branch." \
    --permission-mode bypassPermissions \
    --model "$REVIEW_MODEL" \
    --no-session-persistence \
    2>&1
fix_exit=$?

if (( fix_exit == 0 )); then
    log "CI fix completed successfully"
else
    log "CI fix FAILED (exit $fix_exit)"
fi

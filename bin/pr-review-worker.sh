#!/usr/bin/env bash
# pr-review-worker.sh — runs a Claude Code review for a single PR
#
# Called by pr-watcher.sh as a background process. Handles worktree lifecycle,
# label management, and cleanup.
#
# Usage: pr-review-worker.sh <pr_number> <is_draft> <branch>

set +e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../pr-watcher.conf"

pr_number="$1"
is_draft="$2"
branch="$3"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [review:$pr_number] $*" >> "$LOG_FILE"
}

worktree_dir="$REPO_DIR/.worktrees/pr-review-$pr_number"

cleanup() {
    timeout 10 git -C "$REPO_DIR" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
    rm -f "$STATE_DIR/$pr_number.pid"
    log "cleaned up"
}

log "starting (branch=$branch, draft=$is_draft)"

# Fetch latest and create worktree
git -C "$REPO_DIR" fetch origin "$branch" 2>&1 || true
if ! git -C "$REPO_DIR" worktree add --detach "$worktree_dir" "origin/$branch" 2>&1; then
    log "ERROR — failed to create worktree"
    rm -f "$STATE_DIR/$pr_number.pid"
    exit 1
fi

trap cleanup EXIT

log "created worktree at $worktree_dir"

gh pr edit "$pr_number" --repo "$REPO" --add-label "under-review" 2>&1 || true
log "labeled 'under-review'"

cd "$worktree_dir" || { log "ERROR — cd to worktree failed"; exit 1; }

log "starting claude review..."
review_output=$(mktemp)
"$CLAUDE_BIN" \
    -p "/review-pr PR #$pr_number" \
    --permission-mode bypassPermissions \
    --model "$REVIEW_MODEL" \
    --no-session-persistence \
    --output-format text \
    2>>"$LOG_FILE" > "$review_output"
review_exit=$?

if (( review_exit == 0 )); then
    log "review completed successfully"

    # Post the review as a PR comment
    report=$(cat "$review_output" 2>/dev/null)
    if [[ -n "$report" ]]; then
        gh pr comment "$pr_number" --repo "$REPO" --body "$report" 2>&1 || \
            log "WARNING — failed to post review comment"
        log "posted review report as PR comment"
    fi

    # Mark draft PRs ready for review
    if [[ "$is_draft" == "true" ]]; then
        if gh pr ready "$pr_number" --repo "$REPO" 2>&1; then
            log "marked ready for review"
        else
            log "WARNING — failed to mark ready"
        fi
    fi

    gh pr edit "$pr_number" --repo "$REPO" --remove-label "under-review" --add-label "review-complete" 2>&1 || true
    log "labeled 'review-complete'"

    touch "$STATE_DIR/$pr_number.done"
else
    log "review FAILED (exit $review_exit)"
    gh pr edit "$pr_number" --repo "$REPO" --remove-label "under-review" 2>&1 || true
fi

rm -f "$review_output"

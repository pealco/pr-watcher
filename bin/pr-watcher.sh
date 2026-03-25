#!/usr/bin/env bash
# pr-watcher.sh — long-running daemon that polls GitHub for open PRs and
# launches Claude Code workers in parallel worktrees.
#
# Phases:
#   1. Review new PRs (post findings, mark review-complete)
#   2a. Fix merge conflicts on reviewed PRs
#   2b. Address unresolved review comments
#   2c. Fix failing CI
#   2d. Tag ready-to-merge when all clear
#
# State is tracked in $STATE_DIR to avoid re-reviewing PRs.
# Designed to run as a launchd KeepAlive daemon.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="${PR_WATCHER_CONF:-$SCRIPT_DIR/../pr-watcher.conf}"

if [[ ! -f "$CONF_FILE" ]]; then
    echo "ERROR: config not found at $CONF_FILE" >&2
    echo "Copy pr-watcher.conf.example to pr-watcher.conf and edit it." >&2
    exit 1
fi

# shellcheck source=../pr-watcher.conf.example
source "$CONF_FILE"

# Validate required settings
if [[ -z "${REPO:-}" ]] || [[ -z "${REPO_DIR:-}" ]]; then
    echo "ERROR: REPO and REPO_DIR must be set in $CONF_FILE" >&2
    exit 1
fi

# Defaults for optional settings
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
REVIEW_MODEL="${REVIEW_MODEL:-sonnet}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-1800}"
MAX_RETRY="${MAX_RETRY:-20}"
LOG_FILE="${LOG_FILE:-$HOME/.pr-watcher.log}"
STATE_DIR="${STATE_DIR:-$HOME/.pr-watcher-state}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-10485760}"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-300}"
DONE_STALE_DAYS="${DONE_STALE_DAYS:-7}"
LOCK_FILE="$STATE_DIR/daemon.lock"

mkdir -p "$STATE_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# --- Daemon lock: prevent multiple instances ---
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            local cmd
            cmd=$(ps -p "$old_pid" -o command= 2>/dev/null)
            if [[ "$cmd" == *"pr-watcher.sh"* ]]; then
                echo "ERROR: daemon already running (PID $old_pid)" >&2
                exit 1
            fi
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
}

release_lock() {
    rm -f "$LOCK_FILE"
}

# --- Log rotation ---
rotate_log() {
    local size
    size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null) || size=0
    if (( size > LOG_MAX_BYTES )); then
        mv "$LOG_FILE" "${LOG_FILE}.1"
        log "=== log rotated (previous was ${size} bytes) ==="
    fi
}

# --- PID verification: check PID is alive AND belongs to a worker ---
is_worker_alive() {
    local pidfile="$1"
    local pid
    pid=$(cat "$pidfile" 2>/dev/null) || return 1
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    local cmd
    cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
    [[ "$cmd" == *"pr-"*"-worker.sh"* ]] || return 1
    return 0
}

# Reap finished workers and count running ones
count_running() {
    local count=0
    for pidfile in "$STATE_DIR"/*pid; do
        [[ -f "$pidfile" ]] || continue
        if is_worker_alive "$pidfile"; then
            ((count++))
        else
            rm -f "$pidfile"
        fi
    done
    echo "$count"
}

# --- Worker timeout enforcement ---
kill_stale_workers() {
    local now
    now=$(date '+%s')
    for pidfile in "$STATE_DIR"/*pid; do
        [[ -f "$pidfile" ]] || continue
        if ! is_worker_alive "$pidfile"; then
            rm -f "$pidfile"
            continue
        fi
        local file_epoch
        file_epoch=$(stat -f%m "$pidfile" 2>/dev/null || stat -c%Y "$pidfile" 2>/dev/null) || continue
        local age=$(( now - file_epoch ))
        if (( age > WORKER_TIMEOUT )); then
            local pid
            pid=$(cat "$pidfile" 2>/dev/null)
            local pr_num
            pr_num=$(basename "$pidfile" | sed 's/\..*//')
            log "PR #$pr_num: worker PID $pid timed out after ${age}s (limit ${WORKER_TIMEOUT}s) — killing"
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -9 "$pid" 2>/dev/null || true
            rm -f "$pidfile"
        fi
    done
}

# --- Retry tracking ---
get_retry_count() {
    local pr_num="$1" worker_type="$2"
    local file="$STATE_DIR/${pr_num}.${worker_type}.retries"
    cat "$file" 2>/dev/null || echo "0"
}

increment_retry() {
    local pr_num="$1" worker_type="$2"
    local file="$STATE_DIR/${pr_num}.${worker_type}.retries"
    local count
    count=$(get_retry_count "$pr_num" "$worker_type")
    echo $(( count + 1 )) > "$file"
}

check_retry_limit() {
    local pr_num="$1" worker_type="$2"
    local count
    count=$(get_retry_count "$pr_num" "$worker_type")
    if (( count >= MAX_RETRY )); then
        log "PR #$pr_num: $worker_type exceeded retry limit ($count/$MAX_RETRY) — skipping"
        return 1
    fi
    return 0
}

# --- Reconciliation ---
reconcile() {
    log "reconciling orphaned state..."

    # Remove orphaned labels (worker died without cleanup)
    local orphan_labels=("under-review" "fixing-ci" "deconflicting" "addressing-comments")
    for label in "${orphan_labels[@]}"; do
        local orphan_prs
        orphan_prs=$(gh pr list \
            --repo "$REPO" \
            --state open \
            --label "$label" \
            --json number \
            --jq '.[].number' \
            2>/dev/null) || continue

        for pr_num in $orphan_prs; do
            local has_worker=false
            for pidfile in "$STATE_DIR"/${pr_num}.*pid "$STATE_DIR"/${pr_num}.pid; do
                [[ -f "$pidfile" ]] || continue
                if is_worker_alive "$pidfile"; then
                    has_worker=true
                    break
                else
                    rm -f "$pidfile"
                fi
            done

            if ! $has_worker; then
                log "PR #$pr_num: removing orphaned '$label' label (no running worker)"
                gh pr edit "$pr_num" --repo "$REPO" --remove-label "$label" 2>>"$LOG_FILE" || true
            fi
        done
    done

    # Clean up stale worktrees
    local worktree_base="$REPO_DIR/.worktrees"
    for wt in "$worktree_base"/pr-*; do
        [[ -d "$wt" ]] || continue
        local wt_pr
        wt_pr=$(basename "$wt" | sed 's/pr-[a-z-]*-//')
        local has_worker=false
        for pidfile in "$STATE_DIR"/${wt_pr}.*pid "$STATE_DIR"/${wt_pr}.pid; do
            [[ -f "$pidfile" ]] || continue
            if is_worker_alive "$pidfile"; then
                has_worker=true
                break
            fi
        done
        if ! $has_worker; then
            log "removing stale worktree: $wt"
            timeout 10 git -C "$REPO_DIR" worktree remove "$wt" --force 2>>"$LOG_FILE" || rm -rf "$wt"
        fi
    done

    # Clean up .done and .retries files for closed PRs
    for statefile in "$STATE_DIR"/*.done "$STATE_DIR"/*.retries; do
        [[ -f "$statefile" ]] || continue
        local pr_num
        pr_num=$(basename "$statefile" | sed 's/\..*//')
        local file_epoch
        file_epoch=$(stat -f%m "$statefile" 2>/dev/null || stat -c%Y "$statefile" 2>/dev/null) || continue
        local age_days=$(( ($(date '+%s') - file_epoch) / 86400 ))
        if (( age_days >= DONE_STALE_DAYS )); then
            local pr_state
            pr_state=$(gh pr view "$pr_num" --repo "$REPO" --json state --jq '.state' 2>/dev/null) || pr_state="UNKNOWN"
            if [[ "$pr_state" != "OPEN" ]]; then
                log "PR #$pr_num: cleaning stale state files (state=$pr_state, age=${age_days}d)"
                rm -f "$STATE_DIR/${pr_num}."*
            fi
        fi
    done

    log "reconciliation complete"
}

# --- Graceful shutdown ---
shutdown() {
    log "=== daemon received SIGTERM, shutting down gracefully ==="
    for pidfile in "$STATE_DIR"/*pid; do
        [[ -f "$pidfile" ]] || continue
        if is_worker_alive "$pidfile"; then
            local pid
            pid=$(cat "$pidfile" 2>/dev/null)
            log "sending SIGTERM to worker PID $pid"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    log "waiting for workers to finish (max 30s)..."
    local waited=0
    while (( waited < 30 )); do
        local still_running=0
        for pidfile in "$STATE_DIR"/*pid; do
            [[ -f "$pidfile" ]] || continue
            if is_worker_alive "$pidfile"; then
                ((still_running++))
            fi
        done
        (( still_running == 0 )) && break
        sleep 1
        ((waited++))
    done
    release_lock
    log "=== daemon exiting ==="
    exit 0
}
trap shutdown SIGTERM SIGINT

# --- Startup ---
acquire_lock
log "=== daemon started (PID $$) ==="
log "repo=$REPO repo_dir=$REPO_DIR model=$REVIEW_MODEL parallel=$MAX_PARALLEL"

rotate_log
reconcile
last_reconcile=$(date '+%s')

while true; do
    log "--- poll start ---"

    rotate_log
    kill_stale_workers

    # Periodic reconciliation
    now_epoch=$(date '+%s')
    if (( now_epoch - last_reconcile >= RECONCILE_INTERVAL )); then
        reconcile
        last_reconcile=$now_epoch
    fi

    # --- Phase 1: review new PRs ---
    prs=$(gh pr list \
        --repo "$REPO" \
        --state open \
        --json number,isDraft,labels,headRefName \
        --jq '.[] | select(.labels | map(.name) | (index("review-complete") or index("under-review")) | not) | "\(.number) \(.isDraft) \(.headRefName)"' \
        2>>"$LOG_FILE") || {
        log "ERROR: gh pr list failed"
        sleep "$POLL_INTERVAL"
        continue
    }

    running=$(count_running)

    if [[ -z "$prs" ]]; then
        log "no unreviewed PRs found"
    else
        log "running workers: $running / $MAX_PARALLEL"

        while IFS=' ' read -r pr_number is_draft branch; do
            if [[ -f "$STATE_DIR/$pr_number.done" ]] || [[ -f "$STATE_DIR/$pr_number.pid" ]]; then
                continue
            fi
            if (( running >= MAX_PARALLEL )); then
                log "PR #$pr_number: skipping (at concurrency limit)"
                continue
            fi

            log "PR #$pr_number: dispatching review (draft=$is_draft, branch=$branch)"

            "$SCRIPT_DIR/pr-review-worker.sh" "$pr_number" "$is_draft" "$branch" \
                >>"$LOG_FILE" 2>&1 &
            echo $! > "$STATE_DIR/$pr_number.pid"
            ((running++))

            log "PR #$pr_number: launched as PID $!"
        done <<< "$prs"
    fi

    # --- Phase 2: manage reviewed, non-draft PRs ---

    # Revoke ready-to-merge from PRs that are no longer clean
    ready_prs=$(gh pr list \
        --repo "$REPO" \
        --state open \
        --label "ready-to-merge" \
        --json number,mergeable,headRefName \
        --jq '.[] | "\(.number) \(.mergeable) \(.headRefName)"' \
        2>>"$LOG_FILE") || true

    if [[ -n "$ready_prs" ]]; then
        while IFS=' ' read -r pr_num mergeable_status head_ref; do
            if [[ "$mergeable_status" == "CONFLICTING" ]]; then
                log "PR #$pr_num: revoking ready-to-merge (has conflicts)"
                gh pr edit "$pr_num" --repo "$REPO" --remove-label "ready-to-merge" 2>>"$LOG_FILE" || true
                continue
            fi

            # Revoke if active work labels
            has_work_label=$(gh pr view "$pr_num" --repo "$REPO" --json labels \
                --jq '[.labels[].name] | if (index("deconflicting") or index("fixing-ci") or index("addressing-comments") or index("under-review")) then "yes" else empty end' \
                2>/dev/null) || has_work_label=""
            if [[ -n "$has_work_label" ]]; then
                log "PR #$pr_num: revoking ready-to-merge (active work in progress)"
                gh pr edit "$pr_num" --repo "$REPO" --remove-label "ready-to-merge" 2>>"$LOG_FILE" || true
                continue
            fi

            # Revoke if unresolved review comments appeared
            unresolved=$(gh api "repos/$REPO/pulls/$pr_num/comments" --paginate \
                --jq '
                  [.[] | select(.in_reply_to_id == null) | .id] as $top_ids |
                  [.[] | select(.in_reply_to_id != null) | .in_reply_to_id] as $replied_to |
                  [$top_ids[] | select(. as $id | $replied_to | index($id) | not)] | length
                ' 2>/dev/null) || unresolved=0
            if (( unresolved > 0 )); then
                log "PR #$pr_num: revoking ready-to-merge ($unresolved unresolved comments)"
                gh pr edit "$pr_num" --repo "$REPO" --remove-label "ready-to-merge" 2>>"$LOG_FILE" || true
                continue
            fi
        done <<< "$ready_prs"
    fi

    reviewed_prs=$(gh pr list \
        --repo "$REPO" \
        --state open \
        --label "review-complete" \
        --json number,isDraft,headRefName,mergeable,labels \
        --jq '[.[] | select(.isDraft == false and (.labels | map(.name) | index("ready-to-merge") | not))] | sort_by(.number) | .[] | "\(.number) \(.headRefName) \(.mergeable)"' \
        2>>"$LOG_FILE") || true

    if [[ -n "$reviewed_prs" ]]; then
        running=$(count_running)

        while IFS=' ' read -r pr_number branch mergeable; do
            # Phase 2a: merge conflicts
            if [[ "$mergeable" == "CONFLICTING" ]]; then
                if [[ -f "$STATE_DIR/$pr_number.conflict-fix.pid" ]]; then
                    continue
                fi
                if ! check_retry_limit "$pr_number" "conflict-fix"; then
                    continue
                fi
                if (( running >= MAX_PARALLEL )); then
                    log "PR #$pr_number: skipping conflict fix (at concurrency limit)"
                    continue
                fi

                log "PR #$pr_number: has merge conflicts, dispatching fix (branch=$branch)"
                increment_retry "$pr_number" "conflict-fix"
                "$SCRIPT_DIR/pr-conflict-worker.sh" "$pr_number" "$branch" \
                    >>"$LOG_FILE" 2>&1 &
                echo $! > "$STATE_DIR/$pr_number.conflict-fix.pid"
                ((running++))
                log "PR #$pr_number: conflict fix launched as PID $!"
                continue
            fi

            # Phase 2b: unresolved review comments
            if [[ -f "$STATE_DIR/$pr_number.address-comments.pid" ]]; then
                continue
            fi

            has_unresolved=$(gh api "repos/$REPO/pulls/$pr_number/comments" --paginate \
                --jq '
                  [.[] | select(.in_reply_to_id == null) | .id] as $top_ids |
                  [.[] | select(.in_reply_to_id != null) | .in_reply_to_id] as $replied_to |
                  [$top_ids[] | select(. as $id | $replied_to | index($id) | not)] |
                  length
                ' 2>>"$LOG_FILE") || has_unresolved=0

            if (( has_unresolved > 0 )); then
                if (( running >= MAX_PARALLEL )); then
                    log "PR #$pr_number: $has_unresolved unresolved comments, skipping (at concurrency limit)"
                    continue
                fi

                log "PR #$pr_number: $has_unresolved unresolved comments, dispatching address-comments"
                "$SCRIPT_DIR/pr-address-comments-worker.sh" "$pr_number" "$branch" \
                    >>"$LOG_FILE" 2>&1 &
                echo $! > "$STATE_DIR/$pr_number.address-comments.pid"
                ((running++))
                log "PR #$pr_number: address-comments launched as PID $!"
                continue
            fi

            # Phase 2c: CI failures
            if [[ -f "$STATE_DIR/$pr_number.ci-fix.pid" ]]; then
                continue
            fi

            ci_failed=$(gh pr view "$pr_number" --repo "$REPO" --json statusCheckRollup \
                --jq '[.statusCheckRollup[] | select(.status == "COMPLETED" and .conclusion == "FAILURE")] | length' \
                2>>"$LOG_FILE") || ci_failed=0
            ci_pending=$(gh pr view "$pr_number" --repo "$REPO" --json statusCheckRollup \
                --jq '[.statusCheckRollup[] | select(.status != "COMPLETED")] | length' \
                2>>"$LOG_FILE") || ci_pending=0

            if (( ci_failed > 0 )); then
                if ! check_retry_limit "$pr_number" "ci-fix"; then
                    continue
                fi
                if (( running >= MAX_PARALLEL )); then
                    log "PR #$pr_number: CI failing ($ci_failed checks), skipping (at concurrency limit)"
                    continue
                fi

                log "PR #$pr_number: CI failing ($ci_failed checks), dispatching fix (branch=$branch)"
                increment_retry "$pr_number" "ci-fix"
                "$SCRIPT_DIR/pr-ci-fix-worker.sh" "$pr_number" "$branch" \
                    >>"$LOG_FILE" 2>&1 &
                echo $! > "$STATE_DIR/$pr_number.ci-fix.pid"
                ((running++))
                log "PR #$pr_number: CI fix launched as PID $!"
                continue
            fi

            if (( ci_pending > 0 )); then
                log "PR #$pr_number: CI still running ($ci_pending pending) — waiting"
                continue
            fi

            # Phase 2d: all clear — tag ready-to-merge
            log "PR #$pr_number: CI green, no conflicts, no unresolved comments — tagging ready-to-merge"
            gh pr edit "$pr_number" --repo "$REPO" --add-label "ready-to-merge" 2>>"$LOG_FILE" || true

        done <<< "$reviewed_prs"
    fi

    log "--- poll end ---"
    sleep "$POLL_INTERVAL"
done

# pr-watcher

A daemon that watches your GitHub repo for open PRs and uses [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to review them, fix CI failures, resolve merge conflicts, and address review comments — all automatically.

Runs as a macOS launchd daemon, polling every 60 seconds.

## How it works

```
┌─────────────────────────────────────────────────────────┐
│                    pr-watcher daemon                     │
│                                                         │
│  Poll GitHub ──► For each open PR:                      │
│                                                         │
│  Phase 1: Review                                        │
│    No review yet? → Launch Claude Code review worker    │
│    Posts findings as PR comment, labels review-complete  │
│                                                         │
│  Phase 2: Post-review maintenance                       │
│    2a. Merge conflicts?   → Claude rebases onto main    │
│    2b. Unresolved comments? → Claude addresses them     │
│    2c. CI failing?        → Claude reads logs & fixes   │
│    2d. All clear?         → Labels ready-to-merge       │
│                                                         │
│  Reconciliation (every 5 min):                          │
│    Clean orphaned labels, stale worktrees, old state    │
└─────────────────────────────────────────────────────────┘
```

Each worker runs Claude Code in an isolated git worktree with `--permission-mode bypassPermissions`, so it can read files, edit code, run commands, and push — fully autonomous.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` CLI)
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated
- macOS (for launchd; the scripts themselves are portable bash)
- A local clone of your repository

## Quick start

```bash
git clone https://github.com/pealco/pr-watcher.git
cd pr-watcher

# Creates pr-watcher.conf from the example — edit it first
./install.sh

# Edit the config
$EDITOR pr-watcher.conf

# Re-run to load the daemon
./install.sh
```

The install script:
1. Validates prerequisites
2. Creates `pr-watcher.conf` (you fill in `REPO` and `REPO_DIR`)
3. Installs Claude Code skills to `~/.claude/skills/`
4. Generates and loads a launchd plist

## Configuration

All settings live in `pr-watcher.conf`:

| Setting | Default | Description |
|---------|---------|-------------|
| `REPO` | *(required)* | GitHub `owner/repo` |
| `REPO_DIR` | *(required)* | Path to local clone |
| `CLAUDE_BIN` | `claude` | Path to Claude Code CLI |
| `REVIEW_MODEL` | `sonnet` | Claude model for workers |
| `MAX_PARALLEL` | `3` | Max concurrent workers |
| `POLL_INTERVAL` | `60` | Seconds between polls |
| `WORKER_TIMEOUT` | `1800` | Max seconds per worker (30 min) |
| `MAX_RETRY` | `20` | Max retry attempts per worker type per PR |

## Labels

The daemon uses GitHub labels to track PR state. Create these labels in your repo (any color):

| Label | Meaning |
|-------|---------|
| `under-review` | Claude is reviewing this PR |
| `review-complete` | Review finished |
| `fixing-ci` | Claude is fixing CI failures |
| `deconflicting` | Claude is resolving merge conflicts |
| `addressing-comments` | Claude is addressing review comments |
| `ready-to-merge` | All automated checks passed |

## Skills

Two Claude Code skills ship with pr-watcher and are installed by `install.sh`:

- **`/review-pr`** — Reviews the PR diff for bugs, security issues, and correctness. Posts findings as a PR comment.
- **`/address-comments`** — Works through unresolved review comments, applying fixes or explaining why they don't apply.

## Monitoring

```bash
# Watch the daemon log
tail -f ~/.pr-watcher.log

# Check daemon status
launchctl print gui/$(id -u)/com.pr-watcher

# Stop the daemon
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.pr-watcher.plist

# Start the daemon
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pr-watcher.plist
```

## Architecture

```
pr-watcher/
├── bin/
│   ├── pr-watcher.sh              # Main daemon (poll loop)
│   ├── pr-review-worker.sh        # Review a single PR
│   ├── pr-ci-fix-worker.sh        # Fix CI failures
│   ├── pr-conflict-worker.sh      # Resolve merge conflicts
│   └── pr-address-comments-worker.sh  # Address review comments
├── skills/
│   ├── review-pr.md               # Claude Code skill: PR review
│   └── address-comments.md        # Claude Code skill: address comments
├── templates/
│   └── com.pr-watcher.plist       # launchd plist template
├── pr-watcher.conf.example        # Example configuration
├── install.sh                     # Setup script
└── README.md
```

**State tracking:** `~/.pr-watcher-state/` holds per-PR files:
- `<number>.done` — PR has been reviewed
- `<number>.pid` / `<number>.<type>.pid` — worker is running
- `<number>.<type>.retries` — retry count for a worker type

**Worktrees:** Each worker creates a temporary git worktree under `<repo>/.worktrees/` and cleans it up on exit.

## Limitations

- **macOS only** for launchd integration. The bash scripts work on Linux — you'd just need a different process supervisor (systemd, supervisord, etc.).
- **One repo per daemon.** Run multiple instances with separate config files for multiple repos.
- **No auto-merge.** The daemon labels PRs `ready-to-merge` but doesn't merge them. Use GitHub's auto-merge or merge manually.

## License

MIT

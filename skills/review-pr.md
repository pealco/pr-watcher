---
name: review-pr
description: Review the current PR for bugs, security issues, and correctness
  problems. Reads the diff, evaluates against project conventions, posts findings
  as a PR comment, and optionally applies fixes.
---

# Review PR

Review the current branch's pull request for bugs, security issues, and
correctness problems. Post findings as a PR comment.

**Invoke with:** `/review-pr` or `/review-pr PR #123`

## Process

### 1. Find the PR

```bash
gh pr view --json number,title,headRefName,baseRefName,url
```

If a PR number was provided in the prompt, use that instead.

### 2. Read Project Conventions

Read the project's CLAUDE.md (if it exists) to identify conventions relevant
to the changed files. Extract only rules a reviewer could catch in a diff —
skip rules about tooling, CI, or workflow.

### 3. Get the Diff

```bash
gh pr diff <number>
```

Also read any files referenced in the diff to understand surrounding context.

### 4. Review

Evaluate the diff against this rubric. Only flag issues that meet ALL criteria:

1. Meaningfully impacts correctness, performance, security, or maintainability
2. Is discrete and actionable
3. Is introduced by this diff, not pre-existing
4. The author would likely fix it if aware

**Focus areas:**

- **Edge cases**: nil/null/empty checks, off-by-one, overflow, empty collections
- **Concurrency**: races across await, actor reentrancy, untracked Tasks
- **Security**: SQL injection, XSS, command injection, path traversal, IDOR, leaked secrets
- **Data integrity**: API contract breakage, schema mismatches, silent data loss
- **Error handling**: swallowed errors, catch-all handlers, missing propagation

**Do NOT flag:**
- Style preferences that don't affect correctness
- "Consider adding tests" without a specific edge case
- Pre-existing issues in unchanged code
- Alternative implementations that aren't demonstrably better

### 5. Format Findings

For each finding, include:
- File and line
- Priority: P1 (blocks merge), P2 (should fix), P3 (nice to have)
- Category: bug, security, concurrency, data-integrity, edge-case, error-handling, complexity, convention
- One-line title
- Brief explanation of why it matters

Format as a clean markdown report suitable for a GitHub PR comment.

If no issues found, state that the review found no actionable issues.

### 6. Post as PR Comment

Post the formatted review as a PR comment:

```bash
gh pr comment <number> --body "<formatted review>"
```

### 7. Apply Fixes (if warranted)

For P1 and clear P2 findings, apply fixes directly:

1. Edit the file
2. Keep changes surgical — only what the finding asks for
3. Commit with a descriptive message
4. Push to the PR branch

Do NOT fix P3 findings or anything that's a judgment call.

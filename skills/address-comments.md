---
name: address-comments
description: Address unresolved review comments on the current PR. Fetches
  review threads, evaluates each against the full diff, applies fixes or
  explains why a comment doesn't apply, and replies.
---

# Address Comments

Work through unresolved review comments on the current branch's pull request.
For each comment, evaluate whether the suggestion improves the code, then
either apply a fix or explain why it doesn't apply.

**Invoke with:** `/address-comments` or `/address-comments PR #123`

## Process

### 1. Find the PR

```bash
gh pr view --json number,title,headRefName,url
```

If a PR number was provided in the prompt, use that instead.

### 2. Fetch Review Comments

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq 'sort_by(.created_at)'
```

### 3. Identify Unresolved Comments

A comment is unresolved if it is a top-level review comment (`in_reply_to_id`
is null) and has no replies. Build a set of replied-to IDs and filter to
top-level comments not in that set.

### 4. Get Full Context

Read the full PR diff:

```bash
gh pr diff {number}
```

Also read any files referenced by comments to understand surrounding context.

### 5. Evaluate Each Comment

For each unresolved comment:

**5.1 Understand it.** Read the comment body, the diff hunk, and the full file.

**5.2 Evaluate holistically.** Consider:
- Does this make sense given the full PR diff?
- Does it align with project conventions (CLAUDE.md)?
- Is it a real issue (bug, security, correctness) or a style nit?
- Would applying this break anything else?
- Is the reviewer missing system context?

**5.3 Decide: fix, decline, or partial.**
- **Fix** — genuine improvement. Apply the change.
- **Decline** — doesn't apply or would make code worse. Explain why.
- **Partial** — part is good. Apply the good part, explain the rest.

### 6. Apply Fixes

For comments you're fixing:
1. Edit the file at the referenced path
2. Keep changes surgical
3. Do NOT introduce unrelated changes

### 7. Reply to Each Comment

Reply to every unresolved comment:

```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --method POST \
  -f body="<reply>" \
  -F in_reply_to=<comment-id>
```

**Fixes:** `Fixed — <what was changed>.`

**Declines:** `<Technical reason it doesn't apply.>`

**Partial:** `Partially addressed — <what was fixed>. Regarding <the rest>: <why>.`

Keep replies concise. No filler.

### 8. Commit and Push

```bash
git add <changed-files>
git commit -m "Address review comments"
git push origin HEAD:<branch>
```

### 9. Report

Provide a summary table:

| Comment | File | Action | Detail |
|---------|------|--------|--------|
| "Use const" | src/foo.ts:42 | Fixed | Changed to const |
| "Handle null" | src/bar.py:17 | Declined | Validated upstream |

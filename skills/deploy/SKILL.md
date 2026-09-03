---
name: deploy
description: Commit all changes, push to remote, and confirm deployment
user-invocable: true
disable-model-invocation: true
argument-hint: [commit message]
---

# Deploy

Commit all staged and unstaged changes, push to the remote, and verify the deployment.

## Steps

1. Run `git status` to see what changed. If there are no changes (no modified or untracked files), say "Nothing to deploy" and stop.
2. Run `git diff` (staged + unstaged) to understand the changes.
3. Stage relevant files (prefer specific filenames over `git add -A`). Never stage `.env`, credentials, or `.bak` files.
4. If `$ARGUMENTS` was provided, use it as the commit message. Otherwise, write a concise commit message summarizing the changes.
5. Commit with the message. Always end with: `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`
6. Push to the remote branch.
7. Report the commit hash and confirm the push succeeded.

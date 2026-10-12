#!/bin/bash
# Issue #160 — deployer removes the PR's worktree (looked up by branch, under .worktrees/) before gh pr merge.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
D="$ROOT/agents/deployer.md"
fail=0
has() { # desc fixed-string
  if grep -q -F -- "$2" "$D"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
has "looks up head branch"            'gh pr view <N> --json headRefName --jq .headRefName'
has "lists worktrees by branch"       'git worktree list --porcelain'
has "removes worktree"                'git worktree remove --force'
has "prunes"                          'git worktree prune'
has "scoped to .worktrees/"           '.worktrees/'
has "never removes main checkout"     'never the main checkout'
has "force-safe rationale"            '--match-head-commit'
has "fix cycle re-create"             'git worktree add .worktrees/<dir> <branch>'
has "hard limit clause"               'removes the PR'"'"'s worktree before merging'
# ordering: removal precedes the first gh pr merge command
rm_line=$(grep -n 'git worktree remove --force' "$D" | head -1 | cut -d: -f1)
mg_line=$(grep -n '^ *gh pr merge <N>' "$D" | head -1 | cut -d: -f1)
if [ -n "$rm_line" ] && [ -n "$mg_line" ] && [ "$rm_line" -lt "$mg_line" ]; then echo "ok   removal before merge"; else echo "FAIL removal before merge"; fail=1; fi
exit $fail

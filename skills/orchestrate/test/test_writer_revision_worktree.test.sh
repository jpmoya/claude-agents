#!/bin/bash
# Issue #177 — test-writer revision rounds use a separate -tests worktree, never the developer's.
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
D="$ROOT/agents/test-writer.md"
fail=0
has() { # desc fixed-string
  if grep -q -F -- "$2" "$D"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi
}
has "separate -tests worktree"      'git worktree add .worktrees/<branch>-tests origin/<branch>'
has "fetches origin branch"         'git fetch origin <branch>'
has "fast-forward push"             'git push origin HEAD:<branch>'
has "removes -tests worktree"       'git worktree remove .worktrees/<branch>-tests'
has "never commit in dev worktree"  "Never commit in, reset or edit the developer's"
has "never push others' commits"    'never push commits you did not author'
has "parent self-check"             "new commit's parent equals the previous"
exit $fail

#!/bin/bash
# Issue #164 — sessions open staging->main promotion PRs directly; no pipeline ticket; fixes land on staging first.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
C="$ROOT/CLAUDE.md"; PM="$ROOT/agents/project-manager.md"
fail=0
chk() { if ! grep -qE "$2" "$3"; then echo "FAIL: $1"; fail=1; fi; }
chk "CLAUDE.md: session opens promotion PR itself from a worktree" 'opens the (promotion )?PR itself from a worktree' "$C"
chk "CLAUDE.md: only ancestors of origin/staging" 'ancestors? of `origin/staging`' "$C"
chk "CLAUDE.md: read-only prod-migration ledger check in PR body" 'prod-migration ledger check' "$C"
chk "CLAUDE.md: no pipeline ticket for a promotion" 'No pipeline ticket' "$C"
chk "CLAUDE.md: fixes land on staging first, never only on release branch" 'never committed only to the release branch' "$C"
chk "CLAUDE.md: line 11 carves out promotions" 'except (for )?(a |the )?(staging.main )?promotion' "$C"
chk "project-manager.md: preparing a promotion PR is done directly, merging JP-only" 'preparing a promotion PR.*directly|directly.*preparing a promotion PR' "$PM"
[ $fail -eq 0 ] && echo "PASS"; exit $fail

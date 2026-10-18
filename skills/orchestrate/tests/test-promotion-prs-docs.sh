#!/bin/bash
# Issue #164 — sessions open staging->main promotion PRs directly; no pipeline ticket; fixes land on staging first.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
C="$ROOT/CLAUDE.md"; PM="$ROOT/agents/delivery-lead.md"   # #192: content moved from project-manager.md (now a thin alias)
fail=0
chk() { if ! grep -qE "$2" "$3"; then echo "FAIL: $1"; fail=1; fi; }
chk "CLAUDE.md: session opens promotion PR itself from a worktree" 'opens the (promotion )?PR itself from a worktree' "$C"
chk "CLAUDE.md: only ancestors of origin/staging" 'ancestors? of `origin/staging`' "$C"
chk "CLAUDE.md: read-only prod-migration ledger check in PR body" 'prod-migration ledger check' "$C"
chk "CLAUDE.md: no pipeline ticket for a promotion" 'No pipeline ticket' "$C"
chk "CLAUDE.md: fixes land on staging first, never only on release branch" 'never committed only to the release branch' "$C"
# staging.{1,4}main tolerates the arrow being a multi-byte UTF-8 char: under LC_CTYPE=C, grep's `.` matches one byte, not one codepoint
chk "CLAUDE.md: line 11 carves out promotions" 'except (for )?(a |the )?(staging.{1,4}main )?promotion' "$C"
chk "project-manager.md: preparing a promotion PR is done directly, merging JP-only" 'preparing a promotion PR.*directly|directly.*preparing a promotion PR' "$PM"
# #221 — PR body states the ledger check as found; never pre-claims a prod apply
L=$(grep -F 'Exception — promotion PRs' "$C")
echo "$L" | grep -qE 'as found at writing time' && echo "$L" | grep -qE 'pending — apply and record before merge' || { echo "FAIL: CLAUDE.md: ledger check stated as found, pending files marked 'pending — apply and record before merge'"; fail=1; }
echo "$L" | grep -qE 'never states? (that )?a migration (was )?applied' && echo "$L" | grep -qE 'until its production ledger row exists' && echo "$L" | grep -qE 'applied_at' || { echo "FAIL: CLAUDE.md: no applied/recorded claim until prod ledger row exists; apply reported in a comment quoting applied_at"; fail=1; }
# negative-safe: "applied to production" only inside a never/until clause
if echo "$L" | grep -qiE 'applied to production' && ! echo "$L" | grep -qiE '(never|until)[^.]*applied to production|applied to production[^.]*until'; then echo "FAIL: CLAUDE.md: 'applied to production' outside a never/until clause"; fail=1; fi
# #222 — kill-switched auto-release workflow named in the promotion exception
echo "$L" | grep -qF 'release/auto-' || { echo "FAIL: CLAUDE.md: promotion exception names release/auto-* PRs"; fail=1; }
[ $fail -eq 0 ] && echo "PASS"; exit $fail

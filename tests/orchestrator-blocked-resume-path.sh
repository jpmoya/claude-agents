#!/usr/bin/env bash
# Regression: orchestrator row "any BLOCKED" must name a delivery-lead DECISION as the resume path
# for every code-track BLOCKED, not only ci_pending, and never tell JP to comment go (#333).
set -u
f="$(dirname "$0")/../agents/orchestrator.md"
fail=0
row="$(grep -F '| any `BLOCKED` |' "$f")"
[ -n "$row" ] || { echo "MISSING: any BLOCKED row"; exit 1; }
case "$row" in *'[delivery-lead] DECISION'*) ;; *) echo "row lacks DECISION"; fail=1;; esac
case "$row" in *'Resolves:'*) ;; *) echo "row lacks Resolves:"; fail=1;; esac
case "$row" in *'For `Blocked on: ci_pending` say'*) echo "row still scoped to ci_pending"; fail=1;; esac
case "$row" in *'never ask JP to comment `go`'*) ;; *) echo "row lacks never-ask-go"; fail=1;; esac
grep -n -i 'comment `go` on' "$f" && { echo "go instruction present"; fail=1; }
case "$row" in *'unsupported_project'*) ;; *) echo "row lacks unsupported_project exclusion"; fail=1;; esac
exit $fail

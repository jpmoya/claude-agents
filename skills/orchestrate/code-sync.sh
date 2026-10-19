#!/bin/bash
# Supervisor-tick code sync (docs/host-sync.md). Sourced by supervisor.sh; CLI: code-sync.sh [check|apply]
# Keeps THIS host's claude-agents main checkout equal to origin/main and says whether it is safe to launch.
#   code_sync_state -> fresh | fixable | stale   (read-only apart from `git fetch`)
#     fresh   : on main and origin/main is already contained in HEAD
#     fixable : behind origin/main and/or on another branch, but tracked tree is clean and nothing is unpushed,
#               so `apply` can switch to main and fast-forward without losing anything
#     stale   : cannot be fixed safely (uncommitted tracked edits, unpushed commits on another branch, diverged main)
#               -> the supervisor refuses to launch this tick and logs why
#   code_sync_apply -> checkout main + merge --ff-only (only acts on `fixable`). The supervisor runs it from its EXIT
#               trap, inside the lock, so the running script is never rewritten while bash is still reading it; the
#               NEXT tick runs the new code (<= one tick of lag).
# Fetch has a hard time limit (no timeout(1) on macOS). Offline is not stale: GitHub is down for gh as well.
# Why: cron/launchd ticks never ran the SessionStart pull, so a host ran old code (claude-agents#424).
code_sync_repo() { ( cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null ); }

code_sync_fetch() {  # code_sync_fetch <repo> : fetch origin main, killed after 40 s
  git -C "$1" fetch -q origin main 2>/dev/null &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i+1)); [ "$i" -gt 40 ] && { kill "$pid" 2>/dev/null; echo "code-sync: fetch timed out" >&2; return 1; }
    sleep 1
  done
  wait "$pid" || { echo "code-sync: fetch failed (offline?) - using last known origin/main" >&2; return 1; }
}

code_sync_state() {
  local repo; repo=$(code_sync_repo); [ -n "$repo" ] || { echo fresh; return 0; }
  code_sync_fetch "$repo"
  git -C "$repo" rev-parse -q --verify origin/main >/dev/null || { echo fresh; return 0; }
  local br behind=0 clean=0 unpushed
  br=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)
  git -C "$repo" merge-base --is-ancestor origin/main HEAD 2>/dev/null || behind=1
  [ "$br" = main ] && [ "$behind" = 0 ] && { echo fresh; return 0; }
  git -C "$repo" diff --quiet HEAD -- 2>/dev/null && clean=1
  unpushed=$(git -C "$repo" log --oneline HEAD --not --remotes 2>/dev/null | head -1)
  if [ "$clean" = 1 ] && [ -z "$unpushed" ]; then echo fixable; else echo stale; fi
}

code_sync_apply() {
  local repo; repo=$(code_sync_repo); [ -n "$repo" ] || return 0
  [ "$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)" = main ] || git -C "$repo" checkout -q main 2>/dev/null || return 1
  git -C "$repo" merge --ff-only -q origin/main >/dev/null 2>&1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-check}" in
    check) code_sync_state ;;
    apply) code_sync_apply && echo applied ;;
    *) echo "usage: code-sync.sh [check|apply]" >&2; exit 2 ;;
  esac
fi

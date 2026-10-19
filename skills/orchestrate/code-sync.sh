#!/bin/bash
# Supervisor-tick code sync (docs/host-sync.md). Sourced by supervisor.sh, also runnable: code-sync.sh [check]
# Keeps THIS host's claude-agents checkout equal to origin/main and tells the caller whether it is safe to launch.
#   code_sync_tick  -> prints one of: fresh | updated | stale ; return 0 fresh, 10 updated (caller must re-exec), 20 stale
#   fresh   : HEAD already contains origin/main (equal, or ahead with local work)
#   updated : was behind, fast-forwarded now (main checked out, tracked tree clean)
#   stale   : behind origin/main and cannot fast-forward (other branch / dirty / diverged) -> caller refuses to launch
# Fetch failure (offline) is not stale: gh would be down too; it is logged and the last known origin/main is used.
# Why: cron/launchd ticks never ran the SessionStart pull, so a host ran old code for days (claude-agents#424).
code_sync_repo() { ( cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null ); }

code_sync_tick() {
  local repo; repo=$(code_sync_repo); [ -n "$repo" ] || { echo fresh; return 0; }
  local to=""; command -v timeout >/dev/null 2>&1 && to="timeout 45"; command -v gtimeout >/dev/null 2>&1 && to="gtimeout 45"
  if ! $to git -C "$repo" fetch -q origin main 2>/dev/null; then
    echo "code-sync: fetch failed (offline?) - using last known origin/main" >&2
  fi
  git -C "$repo" rev-parse -q --verify origin/main >/dev/null || { echo fresh; return 0; }
  if git -C "$repo" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then echo fresh; return 0; fi
  local br; br=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)
  if [ "$br" = main ] && git -C "$repo" diff --quiet HEAD -- 2>/dev/null \
     && git -C "$repo" merge --ff-only -q origin/main >/dev/null 2>&1; then echo updated; return 10; fi
  echo stale; return 20
}

# Pure test/CLI entry: print the verdict and exit with its code.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then code_sync_tick; exit $?; fi

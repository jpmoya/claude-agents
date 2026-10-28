#!/bin/bash
# Supervisor-tick code sync (docs/host-sync.md). Sourced by supervisor.sh; CLI: code-sync.sh [check|apply|why]
# Keeps THIS host's claude-agents main checkout equal to origin/main and says whether it is safe to launch.
#   code_sync_state -> fresh | fixable | stale   (read-only apart from `git fetch`)
#     fresh   : on main and origin/main is already contained in HEAD
#     fixable : behind origin/main and/or on another branch, but tracked tree is clean and nothing is unpushed,
#               so `apply` can switch to main and fast-forward without losing anything
#     stale   : cannot be fixed safely (uncommitted tracked edits, unpushed commits on another branch, diverged main)
#               -> the supervisor refuses to launch this tick, logs why AND raises a loud alert (code_sync_alert)
#   code_sync_apply -> checkout main + merge --ff-only (only acts on `fixable`). The supervisor runs it from its EXIT
#               trap, inside the lock, so the running script is never rewritten while bash is still reading it; the
#               NEXT tick runs the new code (<= one tick of lag).
#   code_sync_why  -> one line "<class>\t<detail>" saying why the checkout is stale (no fetch)
# Fetch has a hard time limit (no timeout(1) on macOS). Offline is not stale: GitHub is down for gh as well.
# Why: cron/launchd ticks never ran the SessionStart pull, so a host ran old code (claude-agents#424).
#
# Harness-owned files (CODE_SYNC_IGNORE_DIRTY, default the top-level settings.json): ~/.claude/settings.json is a
# symlink into this checkout, so Claude Code itself rewrites it (model, outputStyle, permission grants) during normal
# use. Such an edit is not "someone broke the checkout" and must never close the guard: it is left out of the dirty
# check, and apply carries it across the fast-forward (if origin/main changed the same lines, origin/main wins and the
# local edit is saved as a patch under <git-dir>/code-sync/). Only the top-level path is ignored; a nested
# settings.json still counts as dirty.
#
# A tripped guard is LOUD (16 h silent outage on the VM, 472 refused ticks nobody saw): every stale tick rewrites
# $PIPE/code-sync.alert (shown by `orchestrate.sh status`) and posts to the existing SLACK_WEBHOOK_URL on the first
# refusal and every CODE_SYNC_ALERT_REPEAT_SECS after; the first fresh tick removes it and posts one "recovered".
CODE_SYNC_IGNORE_DIRTY=${CODE_SYNC_IGNORE_DIRTY-settings.json}
CODE_SYNC_ALERT_REPEAT_SECS=${CODE_SYNC_ALERT_REPEAT_SECS:-3600}

code_sync_repo() { ( cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel 2>/dev/null ); }

_cs_exclude_specs() { local p; for p in $CODE_SYNC_IGNORE_DIRTY; do printf ':(top,exclude)%s\n' "$p"; done; }
_cs_ignored_specs() { local p; for p in $CODE_SYNC_IGNORE_DIRTY; do printf ':(top)%s\n' "$p"; done; }
# _cs_dirty <repo> : tracked paths with uncommitted edits, harness-owned files excluded (one per line)
_cs_dirty() { git -C "$1" diff --name-only HEAD -- $(_cs_exclude_specs) 2>/dev/null; }
# _cs_drift <repo> : harness-owned tracked paths with uncommitted edits (one per line)
_cs_drift() { [ -n "$CODE_SYNC_IGNORE_DIRTY" ] || return 0; git -C "$1" diff --name-only HEAD -- $(_cs_ignored_specs) 2>/dev/null; }

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
  local br behind=0 unpushed
  br=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)
  git -C "$repo" merge-base --is-ancestor origin/main HEAD 2>/dev/null || behind=1
  [ "$br" = main ] && [ "$behind" = 0 ] && { echo fresh; return 0; }
  unpushed=$(git -C "$repo" log --oneline HEAD --not --remotes 2>/dev/null | head -1)
  if [ -z "$(_cs_dirty "$repo")" ] && [ -z "$unpushed" ]; then echo fixable; else echo stale; fi
}

code_sync_why() {  # -> "<class>\t<detail>": dirty | unpushed | dirty+unpushed | unknown (no fetch, read-only)
  local repo br files unpushed cls="" detail=""
  repo=$(code_sync_repo); [ -n "$repo" ] || { printf 'unknown\tno checkout\n'; return 0; }
  br=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null || echo "detached HEAD")
  files=$(_cs_dirty "$repo" | head -5 | tr '\n' ' ' | sed 's/ $//')
  unpushed=$(git -C "$repo" log --oneline HEAD --not --remotes 2>/dev/null | wc -l | tr -d ' ')
  if [ -n "$files" ]; then cls=dirty; detail="uncommitted edits to tracked files: $files"; fi
  if [ "${unpushed:-0}" -gt 0 ]; then
    cls=${cls:+$cls+}unpushed; detail="${detail:+$detail; }$unpushed commit(s) on $br not on any remote"
  fi
  [ -n "$cls" ] || { cls=unknown; detail="on $br, behind origin/main"; }
  printf '%s\t%s (checkout %s)\n' "$cls" "$detail" "$repo"
}

_cs_ff() {  # _cs_ff <repo> : switch to main and fast-forward; git's first error line on stderr
  local repo=$1 err
  if [ "$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)" != main ]; then
    err=$(git -C "$repo" checkout -q main 2>&1) || { echo "code-sync: checkout main failed: $(printf '%s' "$err" | head -1)" >&2; return 1; }
  fi
  err=$(git -C "$repo" merge --ff-only -q origin/main 2>&1) || { echo "code-sync: fast-forward failed: $(printf '%s' "$err" | head -1)" >&2; return 1; }
}

code_sync_apply() {
  local repo; repo=$(code_sync_repo); [ -n "$repo" ] || return 0
  _cs_ff "$repo" 2>/dev/null && return 0
  # Plain fast-forward refused. If harness-owned files carry local edits (the only dirt `fixable` allows), set them
  # aside as a patch, fast-forward, then re-apply the patch. `git apply` is all-or-nothing: on a clash origin/main's
  # version stays (never conflict markers in a live settings file) and the patch is kept for a human.
  local drift patch dir rc=0
  drift=$(_cs_drift "$repo")
  [ -n "$drift" ] || { _cs_ff "$repo"; return 1; }   # rerun only to print git's reason on stderr
  dir="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)/code-sync"; mkdir -p "$dir" || return 1
  patch="$dir/drift-$(date -u +%Y%m%dT%H%M%SZ).patch"
  git -C "$repo" diff --binary HEAD -- $drift > "$patch" && git -C "$repo" checkout -q HEAD -- $drift || return 1
  _cs_ff "$repo" || rc=1
  if git -C "$repo" apply --check "$patch" 2>/dev/null && git -C "$repo" apply "$patch" 2>/dev/null; then
    rm -f "$patch"
  else
    echo "code-sync: local edits to $(printf '%s' "$drift" | tr '\n' ' ')clash with origin/main; kept origin/main's version, local edits saved in $patch" >&2
  fi
  return $rc
}

# --- loud guard (alert file + throttled Slack) ------------------------------------------------------------------------
_cs_iso() { python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1" 2>/dev/null || date -u +%FT%TZ; }

_cs_slack() {  # _cs_slack <text> — existing webhook, tags only (repo convention: no file names, no command output)
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  local body; body=$(jq -nc --arg t "$1" '{text:$t}' 2>/dev/null) || body="{\"text\":\"$1\"}"
  curl -s --max-time 10 -X POST -H 'Content-type: application/json' --data "$body" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
}

_cs_tags() {
  printf 'release=%s environment=%s route=supervisor/code-sync' \
    "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo unknown)" "$(hostname -s 2>/dev/null || echo unknown)"
}

# code_sync_alert <class> <detail> — called on every refused tick (and on a failed apply). Keeps a streak in
# $PIPE/code-sync.alert-state ("<since epoch> <ticks> <last slack epoch>"), rewrites the human-readable
# $PIPE/code-sync.alert, and posts to Slack on the first refusal and then at most once per CODE_SYNC_ALERT_REPEAT_SECS.
code_sync_alert() {
  local cls=$1 detail=$2 pipe=${PIPE:-} st now since=0 n=0 last=0 host
  [ -n "$pipe" ] || return 0
  mkdir -p "$pipe" 2>/dev/null; st="$pipe/code-sync.alert-state"; now=$(date +%s); host=$(hostname -s 2>/dev/null || echo unknown)
  [ -s "$st" ] && read -r since n last < "$st"
  case "$since" in ''|*[!0-9]*) since=0 ;; esac; case "$n" in ''|*[!0-9]*) n=0 ;; esac; case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$since" -gt 0 ] || since=$now
  n=$((n + 1))
  printf '%s code-sync: supervisor on %s has refused to launch since %s (%s ticks) - %s: %s. Fix: commit the edits through a PR or discard them (git checkout -- <file>), push or move unpushed commits to a worktree; the next tick then fast-forwards and clears this alert.\n' \
    "$(date -u +%FT%TZ)" "$host" "$(_cs_iso "$since")" "$n" "$cls" "$detail" > "$pipe/code-sync.alert"
  if [ "$last" -eq 0 ] || [ $((now - last)) -ge "$CODE_SYNC_ALERT_REPEAT_SECS" ]; then
    _cs_slack "code-sync: supervisor refusing to launch on stale pipeline code: $(_cs_tags) reason=$cls refused_since=$(_cs_iso "$since") ticks=$n"
    last=$now
  fi
  printf '%s %s %s\n' "$since" "$n" "$last" > "$st"
}

# code_sync_clear_alert — the guard is open again: drop the alert, post one "recovered" if a streak was alerted.
code_sync_clear_alert() {
  local pipe=${PIPE:-} st since=0 n=0 last=0
  [ -n "$pipe" ] || return 0
  st="$pipe/code-sync.alert-state"
  [ -e "$st" ] || [ -e "$pipe/code-sync.alert" ] || return 0
  [ -s "$st" ] && read -r since n last < "$st"
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  rm -f "$st" "$pipe/code-sync.alert"
  _cs_slack "code-sync: recovered, supervisor launching again: $(_cs_tags) refused_since=$( [ "$since" -gt 0 ] && _cs_iso "$since" || echo unknown) ticks=${n:-0}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-check}" in
    check) code_sync_state ;;
    apply) code_sync_apply && echo applied ;;
    why) code_sync_why ;;
    *) echo "usage: code-sync.sh [check|apply|why]" >&2; exit 2 ;;
  esac
fi

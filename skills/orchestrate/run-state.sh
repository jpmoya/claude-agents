#!/bin/bash
# Shared run-state derivation + the one fire-and-forget reporter call pattern.
# Sourced by orchestrate.sh, supervisor.sh and hooks/report-status-hook.sh — see issue #10 Design.
#
# Caller-independent by design (SA's NOTE correction on #10): a hook call site has neither a
# caller-provided $HERE nor $LOGDIR, so this file resolves its own directory from its own
# BASH_SOURCE and sources config.sh itself, unconditionally (config.sh's defaults are all
# ${VAR:-default}, so an env override the caller already set — PIPE/QUEUE/HOME in tests — survives
# being re-sourced here).
RS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$RS_DIR/config.sh"

# derive_runs — prints one tab-separated record per recorded orchestrator:
#   issue, repo_path, state_code, pid, started_at, last_activity_at, restarts, stage
# state_code precedence (design table, checked in order): pid alive -> running; else .closed ->
# closed (issue #51: reconcile-status.sh saw the GitHub issue CLOSED; never emitted in runs[], only
# in the payload's completed[]); else .stopped -> stopped; else .held -> held; else .done -> done; else -> restarting. A queue entry with no
# orch-<issue>.pid at all is a separate record: state_code=queued, pid empty.
# last_activity_at is an epoch integer (newest mtime among orch-<n>.log / run-<n>-*.log) — the
# caller (report-status.sh) converts it to ISO-8601Z for the payload. File contents are never read.
# mtimes are read via python3's os.path.getmtime — no GNU stat/date flags (AC11), portable to
# macOS bash 3.2.
_rs_mtime() {  # _rs_mtime <file> -> epoch int, or empty if it doesn't exist
  [ -e "$1" ] || return 0
  python3 -c "import os,sys
try: print(int(os.path.getmtime(sys.argv[1])))
except OSError: pass" "$1" 2>/dev/null
}

_rs_stage_for() {  # _rs_stage_for <issue> -> agent name of the newest-mtime run-<issue>-<agent>.log, else empty
  local issue=$1 f best_f="" best_ts=-1 ts base agent
  for f in "$PIPE"/run-"$issue"-*.log; do
    [ -e "$f" ] || break
    ts=$(_rs_mtime "$f"); [ -n "$ts" ] || continue
    if [ "$ts" -gt "$best_ts" ]; then best_ts=$ts; best_f=$f; fi
  done
  [ -n "$best_f" ] || return 0
  base=$(basename "$best_f" .log)          # run-<issue>-<agent>
  agent=${base#run-"$issue"-}
  printf '%s' "$agent"
}

_rs_last_activity_for() {  # _rs_last_activity_for <issue> -> newest epoch among orch-<issue>.log and run-<issue>-*.log
  local issue=$1 f ts best=""
  for f in "$PIPE/orch-$issue.log" "$PIPE"/run-"$issue"-*.log; do
    [ -e "$f" ] || continue
    ts=$(_rs_mtime "$f"); [ -n "$ts" ] || continue
    if [ -z "$best" ] || [ "$ts" -gt "$best" ]; then best=$ts; fi
  done
  printf '%s' "$best"
}

derive_runs() {
  local f issue pid repo state_code started restarts stage last_activity
  for f in "$PIPE"/orch-*.pid; do
    [ -e "$f" ] || break
    issue=$(basename "$f" .pid); issue=${issue#orch-}
    pid=$(cat "$f" 2>/dev/null)
    repo=$(cat "$PIPE/orch-$issue.repo" 2>/dev/null || echo "?")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      state_code=running
    elif [ -f "$PIPE/orch-$issue.closed" ]; then
      state_code=closed
    elif [ -f "$PIPE/orch-$issue.stopped" ]; then
      state_code=stopped
    elif [ -f "$PIPE/orch-$issue.held" ]; then
      state_code=held
    elif [ -f "$PIPE/orch-$issue.done" ]; then
      state_code=done
    else
      state_code=restarting
    fi
    started=$(cat "$PIPE/orch-$issue.start" 2>/dev/null || echo "")
    restarts=$(python3 -c "import json; print(json.load(open('$PIPE/orch-$issue.restarts')).get('total',0))" 2>/dev/null || echo 0)
    stage=$(_rs_stage_for "$issue")
    last_activity=$(_rs_last_activity_for "$issue")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$issue" "$repo" "$state_code" "$pid" "$started" "$last_activity" "$restarts" "$stage"
  done

  for f in "$QUEUE"/orch-*.json; do
    [ -e "$f" ] || break
    issue=$(python3 -c "import json; print(json.load(open('$f'))['issue'])" 2>/dev/null)
    [ -n "$issue" ] || continue
    # a queue entry for an issue that also has a live/known orch-*.pid record is already covered above
    [ -e "$PIPE/orch-$issue.pid" ] && continue
    repo=$(python3 -c "import json; print(json.load(open('$f'))['repo'])" 2>/dev/null)
    started=$(python3 -c "import json; print(json.load(open('$f')).get('queued_at',''))" 2>/dev/null)
    printf '%s\t%s\tqueued\t\t%s\t\t0\t\n' "$issue" "$repo" "$started"
  done
}

# report_status_async — the one fire-and-forget call pattern used by all three call sites
# (orchestrate.sh, supervisor.sh, hooks/report-status-hook.sh). Never blocks, never fails the
# caller: backgrounded, output redirected to its own log, fd 9 (supervisor.sh's single-flight
# tick lock, if any) is explicitly closed so a backgrounded child never holds it past the tick.
report_status_async() {   # fire-and-forget: never blocks, never fails the caller
  mkdir -p "$LOGDIR" 2>/dev/null
  ( "$RS_DIR/report-status.sh" "${1:-event}" >>"$LOGDIR/report-status.log" 2>&1 & ) 9>&- || true
}

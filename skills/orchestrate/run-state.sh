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
# orch-<issue>.pid at all is a separate record: state_code=queued, pid empty. A .closed marker with no
# .pid and no queue entry is a closed record too (a ticket reconciled while queued-only).
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

_rs_ps_lines() {  # live claude processes: <start_epoch> TAB <PIPELINE_ISSUE> TAB <command line>; RS_PS_CMD overrides (tests)
  if [ -n "${RS_PS_CMD:-}" ]; then bash -c "$RS_PS_CMD" 2>/dev/null; return 0; fi
  if [ "$(uname)" = "Linux" ]; then
    python3 - <<'PY' 2>/dev/null
import os, re
hz = os.sysconf("SC_CLK_TCK")
try:
    btime = [int(l.split()[1]) for l in open("/proc/stat") if l.startswith("btime")][0]
except Exception:
    btime = 0
for pid in os.listdir("/proc"):
    if not pid.isdigit():
        continue
    try:
        argv = open("/proc/%s/cmdline" % pid, "rb").read().split(b"\0")
        if not argv or os.path.basename(argv[0].decode("utf-8", "replace")) != "claude":
            continue
        env = dict(kv.split(b"=", 1) for kv in open("/proc/%s/environ" % pid, "rb").read().split(b"\0") if b"=" in kv)
        issue = env.get(b"PIPELINE_ISSUE", b"").decode()
        start = btime + int(open("/proc/%s/stat" % pid).read().rsplit(")", 1)[1].split()[19]) // hz
        cmd = " ".join(a.decode("utf-8", "replace") for a in argv if a).replace("\t", " ").replace("\n", " ")
        print("%d\t%s\t%s" % (start, issue, cmd))
    except Exception:
        continue
PY
  else
    # macOS: `ps eww` prints the environment after the command line; start time is not needed to rank
    # parallel stages, so use pid order (newer pid = newer start) as the epoch stand-in.
    ps -axeww -o pid=,command= 2>/dev/null | awk '/--agent / && /PIPELINE_ISSUE=/ {
      pid=$1; iss=$0; sub(/.*PIPELINE_ISSUE=/, "", iss); sub(/[ \t].*/, "", iss);
      cmd=$0; sub(/^[ \t]*[0-9]+ +/, "", cmd); printf "%d\t%s\t%s\n", pid, iss, cmd }'
  fi
}

_rs_live_stage() {  # _rs_live_stage <issue> <alive 0|1> -> --agent of the newest-start live process with PIPELINE_ISSUE=<issue>;
  # orchestrator alive + no stage line -> "orchestrator"; nothing alive -> empty
  local issue=$1 alive=${2:-0} best
  best=$(_rs_ps_lines | awk -F'\t' -v want="$issue" '$2 == want && match($3, /--agent [^ ]+/) {
    a = substr($3, RSTART + 8, RLENGTH - 8); if (!found || $1 + 0 >= best) { best = $1 + 0; found = 1; agent = a } }
    END { if (found) print agent }')
  if [ -n "$best" ]; then printf '%s' "$best"
  elif [ "$alive" = 1 ]; then printf 'orchestrator'; fi
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
    stage=$(_rs_live_stage "$issue" "$([ "$state_code" = running ] && echo 1 || echo 0)")
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

  # A closed ticket that never had a pid record (it was reconciled while queued-only): reconcile-status.sh
  # leaves orch-<issue>.closed + orch-<issue>.repo, so it still reaches completed[] (issue #51).
  for f in "$PIPE"/orch-*.closed; do
    [ -e "$f" ] || break
    issue=$(basename "$f" .closed); issue=${issue#orch-}
    [ -e "$PIPE/orch-$issue.pid" ] && continue
    [ -e "$QUEUE/orch-$issue.json" ] && continue
    repo=$(cat "$PIPE/orch-$issue.repo" 2>/dev/null || echo "?")
    printf '%s\t%s\tclosed\t\t\t\t0\t\n' "$issue" "$repo"
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

#!/bin/bash
# Refresh the status board's local truth from GitHub (issue #51). Usage: reconcile-status.sh [--force]
#
# For every local record (orch-<n>.pid + orch-<n>.repo) that is open-ish (running / restarting / held)
# or finished within the last 48 h (done / stopped), and has no orch-<n>.closed yet, one
# `gh issue view <n> --json state,closedAt,comments`:
#   CLOSED -> orch-<n>.closed (line 1 = closedAt), touch .done, drop .held/.stopped/.alert and the queue
#             entry, log a line to supervisor.log
#   OPEN   -> orch-<n>.marker = the latest real routing marker name (removed when there is none)
# then ONE report_status_async if anything changed. The reporter and builder only read these files, so
# they stay network-free.
#
# Throttled to one pass per RECONCILE_INTERVAL_SECS (stamp file) unless --force. Always exits 0, never
# prints: a gh failure (offline, rate limit) is a silent no-op. bash 3.2 portable (no GNU stat/date flags).
RC_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$RC_HERE/config.sh"
. "$RC_HERE/pipeline-lib.sh"
. "$RC_HERE/run-state.sh"     # derive_runs, _rs_mtime, report_status_async
. "$RC_HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || . "$HOME/.claude/hooks/pipeline-markers.sh" 2>/dev/null

RECONCILE_INTERVAL_SECS=600
RECENT_SECS=$((48 * 3600))      # done/stopped records older than this are not refreshed
STAMP="$PIPE/status-reconcile.stamp"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

command -v jq >/dev/null 2>&1 && command -v gh >/dev/null 2>&1 || exit 0
mkdir -p "$PIPE" "$LOGDIR" 2>/dev/null

now=$(date +%s)
if [ "$FORCE" -eq 0 ]; then
  stamp_mtime=$(_rs_mtime "$STAMP")
  if [ -n "$stamp_mtime" ] && [ $((now - stamp_mtime)) -lt "$RECONCILE_INTERVAL_SECS" ]; then
    exit 0
  fi
fi
touch "$STAMP" 2>/dev/null

rc_log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOGDIR/supervisor.log" 2>/dev/null; }

MARKER_JQ="$(marker_last_jq)"
changed=0

# Snapshot first: the pass edits the very files derive_runs reads.
records=$(derive_runs)
while IFS=$'\t' read -r issue repo state pid started last_activity restarts stage; do
  [ -n "$issue" ] && [ -n "$pid" ] || continue                 # queued-only entries have no pid record
  [ -f "$PIPE/orch-$issue.repo" ] || continue
  case "$state" in
    running|restarting|held) ;;
    done|stopped)
      [ -n "$last_activity" ] || last_activity=$(_rs_mtime "$PIPE/orch-$issue.pid")
      [ -n "$last_activity" ] && [ $((now - last_activity)) -le "$RECENT_SECS" ] || continue ;;
    *) continue ;;                                             # closed (already reconciled) or unknown
  esac

  info=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json state,closedAt,comments 2>/dev/null </dev/null) || continue
  gh_state=$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null) || continue
  [ -n "$gh_state" ] || continue
  marker=$(printf '%s' "$info" | jq -r "$MARKER_JQ" 2>/dev/null) || marker=""
  case "$marker" in
    none|"") marker="" ;;
    *) marker=$(printf '%s' "$marker" | sed -e 's/^\*\*\[[^]]*\] //' -e 's/\*\*.*$//' -e 's/:.*$//' -e 's/[[:space:]]*$//') ;;
  esac

  old_marker=$(head -n1 "$PIPE/orch-$issue.marker" 2>/dev/null)
  if [ -n "$marker" ]; then
    [ "$marker" = "$old_marker" ] || { printf '%s\n' "$marker" > "$PIPE/orch-$issue.marker"; changed=1; }
  elif [ -f "$PIPE/orch-$issue.marker" ]; then
    rm -f "$PIPE/orch-$issue.marker"; changed=1
  fi

  if [ "$gh_state" = "CLOSED" ]; then
    closed_at=$(printf '%s' "$info" | jq -r '.closedAt // empty' 2>/dev/null)
    case "$closed_at" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) closed_at=$(date -u +%FT%TZ) ;;
    esac
    printf '%s\n' "$closed_at" > "$PIPE/orch-$issue.closed"
    touch "$PIPE/orch-$issue.done"
    rm -f "$PIPE/orch-$issue.held" "$PIPE/orch-$issue.stopped" "$PIPE/orch-$issue.alert" "$QUEUE/orch-$issue.json"
    rc_log "[reconcile] #$issue — issue closed on GitHub ($closed_at), moved to completed"
    changed=1
  fi
done <<EOF
$records
EOF

[ "$changed" -eq 1 ] && report_status_async "reconcile"
exit 0

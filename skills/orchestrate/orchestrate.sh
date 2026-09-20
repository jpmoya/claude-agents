#!/bin/bash
# Launch the pipeline orchestrator as a detached headless Claude Code process.
# Usage:
#   orchestrate.sh <repo-path> <issue> [extra instructions...]   launch (queues if at max)
#   orchestrate.sh status [issue]                                 list running/queued orchestrators
#   orchestrate.sh tail <issue> [lines]                           tail an orchestrator's log
#   orchestrate.sh stop <issue>                                   kill an orchestrator (prevents auto-restart)
#   orchestrate.sh queue                                          show the queue
#   orchestrate.sh --force <repo-path> <issue>                   launch even if agent-in-progress is set (other machine died)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"
# shared launcher helpers: SETSID probe, capacity checks, marker jq expression (issue #8)
source "$HERE/pipeline-lib.sh"
# shared run-state derivation (used by `status` below) + report_status_async (issue #10)
source "$HERE/run-state.sh"
# routing-marker vocabulary (marker_re), shared with the supervisor, the handoff hook and the orchestrator
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"
mkdir -p "$PIPE" "$QUEUE"
FORCE=0; args=()
for a in "$@"; do [ "$a" = "--force" ] && FORCE=1 || args+=("$a"); done
set -- "${args[@]}"

case "${1:-}" in
  status)
    ISSUE="${2:-}"
    # State derivation is shared with the reporter (run-state.sh's derive_runs) — issue #10 AC14:
    # only this derivation moved; every echo/printf format string, the found=1-after-issue-filter
    # behaviour ("no orchestrators recorded" fires only when the orch-*.pid glob itself is empty,
    # never on a filter that matches nothing), the per-run gh marker fetch, and the runs -> alerts
    # -> queued ordering below are unchanged.
    if ! ls "$PIPE"/orch-*.pid >/dev/null 2>&1; then
      echo "no orchestrators recorded"
    else
      while IFS=$'\t' read -r n repo state_code pid started last_activity restarts stage; do
        [ -n "$n" ] || continue
        [ "$state_code" = "queued" ] && continue   # queued entries are the section below, unchanged
        [ -n "$ISSUE" ] && [ "$n" != "$ISSUE" ] && continue
        case "$state_code" in
          running)    state="running (pid $pid)" ;;
          stopped)    state="stopped (manual)" ;;
          held)       state="held (needs JP)" ;;
          done|closed) state="done" ;;
          *)          state="exited (will auto-restart)" ;;
        esac
        gh_out=$( (cd "$repo" 2>/dev/null && gh issue view "$n" --json state,comments \
          --jq "{state, last: ($(marker_last_jq))}") 2>/dev/null)
        gh_state=$(printf '%s' "$gh_out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('state','?'))" 2>/dev/null || echo "?")
        last=$(printf '%s' "$gh_out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('last','?'))" 2>/dev/null || echo "?")
        # Local files (pid/held/done) never learn that an issue was closed directly on GitHub
        # (JP finishing it by hand, bypassing the deployer stage) — without this override a
        # closed, fully-done issue keeps reporting "held (needs JP)" indefinitely (#216 session,
        # 2026-09-18: #151 and #183 were reported as still needing JP days after being closed).
        [ "$gh_state" = "CLOSED" ] && state="done (issue closed)"
        echo "#$n  $state  repo=$repo  latest marker: $last  log=$PIPE/orch-$n.log"
      done <<< "$(derive_runs)"
    fi
    # Reporter health (design #10 §4.2): >=3 consecutive push failures earn one extra line so a
    # broken reporter (bad token, typo'd URL) doesn't render identically to a genuinely dead host.
    # No effect unless that state exists — absent here, so the golden stays byte-identical (AC14).
    if [ -f "$PIPE/status-push.state" ]; then
      push_health=$(python3 -c "
import json
try:
    d = json.load(open('$PIPE/status-push.state'))
except Exception:
    d = {}
fails = d.get('fails', 0)
if isinstance(fails, int) and fails >= 3:
    print('%s|%s' % (d.get('last_status', '?'), d.get('last_attempt_epoch', 0)))
" 2>/dev/null)
      if [ -n "$push_health" ]; then
        code=${push_health%%|*}; epoch=${push_health##*|}
        ts=$(python3 -c "
import datetime
try: print(datetime.datetime.fromtimestamp(int('$epoch'), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
except Exception: print('?')
" 2>/dev/null)
        echo "!! status push failing: HTTP $code since $ts"
      fi
    fi
    # Surface any unresolved alerts
    for af in "$PIPE"/orch-*.alert; do
      [ -e "$af" ] || break
      echo "!! ALERT: $(cat "$af")"
    done
    if ls "$QUEUE"/*.json >/dev/null 2>&1; then
      echo "--- queued ---"
      for qf in $(ls -1 "$QUEUE"/*.json 2>/dev/null | sort -t- -k2 -n); do
        q_issue=$(python3 -c "import json; d=json.load(open('$qf')); print(d['issue'])")
        q_repo=$(python3 -c "import json; d=json.load(open('$qf')); print(d['repo'])")
        queued_at=$(python3 -c "import json; d=json.load(open('$qf')); print(d.get('queued_at','?'))")
        nb=$(python3 -c "import json,time; nb=json.load(open('$qf')).get('not_before',0); d=int(nb-time.time()); print(f'ready' if d<=0 else f'in {d}s')" 2>/dev/null)
        echo "#$q_issue  queued since $queued_at  $nb  repo=$q_repo"
      done
    fi
    ;;
  tail)
    tail -n "${3:-20}" "$PIPE/orch-$2.log"
    ;;
  stop)
    pid=$(cat "$PIPE/orch-$2.pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      # $pid is the nohup'd bash wrapper; SIGTERM does not reach its claude child,
      # which kept driving #611 for 14 min after a stop (2026-09-13). Kill the
      # child too. Stage processes the orchestrator launched are left alone.
      pkill -TERM -P "$pid" 2>/dev/null
      kill "$pid" && echo "stopped orchestrator for #$2 (pid $pid)"
    else
      echo "orchestrator for #$2 not running"
    fi
    touch "$PIPE/orch-$2.stopped"
    rm -f "$QUEUE/orch-$2.json"
    report_status_async "stop"   # event push: run stopped (design #10 §4.4)
    echo "wrote tombstone — supervisor will not auto-restart #$2"
    ;;
  queue)
    if ! ls "$QUEUE"/*.json >/dev/null 2>&1; then
      echo "queue is empty"
    else
      for qf in $(ls -1 "$QUEUE"/*.json 2>/dev/null | sort -t- -k2 -n); do
        q_issue=$(python3 -c "import json; d=json.load(open('$qf')); print(d['issue'])")
        q_repo=$(python3 -c "import json; d=json.load(open('$qf')); print(d['repo'])")
        queued_at=$(python3 -c "import json; d=json.load(open('$qf')); print(d.get('queued_at','?'))")
        echo "#$q_issue  queued since $queued_at  repo=$q_repo"
      done
    fi
    ;;
  *)
    REPO="${1:?repo path required}"; ISSUE="${2:?issue number required}"; shift 2; EXTRA="$*"
    REPO=$(cd "$REPO" && pwd)
    OWNER_REPO=$(cd "$REPO" && gh repo view --json nameWithOwner --jq .nameWithOwner)
    if [ -f "$PIPE/orch-$ISSUE.pid" ] && kill -0 "$(cat "$PIPE/orch-$ISSUE.pid")" 2>/dev/null; then
      echo "orchestrator for #$ISSUE already running (pid $(cat "$PIPE/orch-$ISSUE.pid")); use 'stop' first" >&2; exit 1
    fi
    # Cross-machine guard: agent-in-progress on an issue this machine does not own (never launched here, or launched
    # here but already released via .label-cleared) means another machine is driving it.
    if [ "$FORCE" -eq 0 ] && { [ ! -f "$PIPE/orch-$ISSUE.repo" ] || [ -f "$PIPE/orch-$ISSUE.label-cleared" ]; } \
       && (cd "$REPO" && gh issue view "$ISSUE" --json labels --jq '[.labels[].name] | index("'"$LABEL_IN_PROGRESS"'") != null' 2>/dev/null | grep -q true); then
      echo "#$ISSUE carries $LABEL_IN_PROGRESS but nothing is running here — running elsewhere? check the other machine's status, or --force" >&2; exit 1
    fi
    rm -f "$QUEUE/orch-$ISSUE.json"   # a manual launch supersedes a queued one; never both
    # Launching consumes agent-go (the shared-dispatch pool) and claims the issue for this machine. Crash restarts are
    # the local supervisor's job, not the label's; the supervisor drops agent-in-progress when the run is done or parked.
    (cd "$REPO" && gh issue edit "$ISSUE" --add-label "$LABEL_IN_PROGRESS" --remove-label "$LABEL_GO" 2>/dev/null) || true
    # Clear tombstones and restart state on manual launch
    rm -f "$PIPE/orch-$ISSUE".{stopped,held,done,closed,marker,alert,label-cleared,start,exit} "$PIPE/orch-$ISSUE.restarts"
    # Persist on both the launch and queued paths: supervisor.sh rebuilds the queue JSON from this file.
    printf '%s' "$EXTRA" > "$PIPE/orch-$ISSUE.extra"
    # Ticket title for the status board (#29) — fetched once here, before the capacity check so a queued run has it
    # too; the status reporter only ever reads the file. A failed or empty fetch leaves no title file and never blocks
    # the launch.
    TITLE=$(cd "$REPO" && gh issue view "$ISSUE" --json title --jq .title 2>/dev/null) || TITLE=""
    if [ -n "$TITLE" ]; then
      printf '%s\n' "$TITLE" > "$PIPE/orch-$ISSUE.title"
    else
      rm -f "$PIPE/orch-$ISSUE.title"
    fi
    if ! has_capacity; then
      python3 -c "
import json, datetime, time
with open('$QUEUE/orch-$ISSUE.json', 'w') as f:
    json.dump({'issue': '$ISSUE', 'repo': '$REPO', 'extra': '''$EXTRA''', 'reason': 'queued',
               'queued_at': datetime.datetime.utcnow().strftime('%FT%TZ'), 'not_before': int(time.time())}, f)
"
      echo "queued #$ISSUE ($(count_running)/$MAX_CONCURRENT slots full, $(mem_available_mb)MB avail) — supervisor will auto-launch when a slot opens"
      echo "check: ~/.claude/skills/orchestrate/orchestrate.sh queue"
      rm -f "$PIPE/orch-$ISSUE.pid"   # queued, not running: a stale dead pid makes the supervisor read this as a run that just ended (#22)
      exit 0
    fi
    # The headless session IS the orchestrator (--agent), not a wrapper that calls Agent(orchestrator):
    # a prompt arguing "you are the exception to the CLAUDE.md rule" reads as a prompt injection and
    # was intermittently refused (#217, #151, #637 — 2026-09-17).
    PROMPT="Drive $OWNER_REPO#$ISSUE through the pipeline. Repo: $REPO. Read the latest marker on the issue and continue from there. $EXTRA"
    printf '\n===== [%s] LAUNCH issue=%s reason=manual =====\n' "$(date -u +%FT%TZ)" "$ISSUE" >> "$PIPE/orch-$ISSUE.log"
    cd "$REPO"
    CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup $SETSID bash -c '
      echo 300 > /proc/self/oom_score_adj 2>/dev/null
      claude --dangerously-skip-permissions --agent orchestrator -p "$1"
      echo $? > "$2"
    ' _ "$PROMPT" "$PIPE/orch-$ISSUE.exit" >> "$PIPE/orch-$ISSUE.log" 2>&1 &
    echo $! > "$PIPE/orch-$ISSUE.pid"; echo "$REPO" > "$PIPE/orch-$ISSUE.repo"
    date -u +%FT%TZ > "$PIPE/orch-$ISSUE.start"; date -u +%FT%TZ > "$PIPE/orch-$ISSUE.launched-at"
    report_status_async "launch"   # event push: run launched (design #10 §4.4)
    echo "launched orchestrator for $OWNER_REPO#$ISSUE  pid=$!  log=$PIPE/orch-$ISSUE.log"
    echo "check: ~/.claude/skills/orchestrate/orchestrate.sh status $ISSUE"
    ;;
esac

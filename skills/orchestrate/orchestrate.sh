#!/bin/bash
# Launch the pipeline orchestrator as a detached headless Claude Code process.
# Usage:
#   orchestrate.sh <repo-path> <issue> [extra instructions...]   launch (queues if at max)
#   orchestrate.sh status [issue]                                 list running/queued orchestrators
#   orchestrate.sh tail <issue> [lines]                           tail an orchestrator's log
#   orchestrate.sh stop <issue>                                   kill an orchestrator (prevents auto-restart)
#   orchestrate.sh queue                                          show the queue
set -euo pipefail
PIPE=/tmp/pipeline
SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there
QUEUE="$PIPE/queue"
mkdir -p "$PIPE" "$QUEUE"
MAX_CONCURRENT=3
MEM_FLOOR_MB=1200

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid; do
    [ -e "$f" ] || break
    kill -0 "$(cat "$f")" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

mem_available_mb() {
  if [ -r /proc/meminfo ]; then awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo
  else vm_stat 2>/dev/null | awk '/page size of/ {ps=$8} /Pages free|Pages inactive|Pages speculative/ {gsub(/\./,"",$NF); p+=$NF} END {print int(p*ps/1048576)}'
  fi
}

has_capacity() {
  [ "$(count_running)" -lt "$MAX_CONCURRENT" ] && [ "$(mem_available_mb)" -ge "$MEM_FLOOR_MB" ]
}

case "${1:-}" in
  status)
    ISSUE="${2:-}"
    found=0
    for f in "$PIPE"/orch-*.pid; do
      [ -e "$f" ] || { [ $found -eq 0 ] && echo "no orchestrators recorded"; break; }
      n=$(basename "$f" .pid); n=${n#orch-}
      [ -n "$ISSUE" ] && [ "$n" != "$ISSUE" ] && continue
      found=1
      pid=$(cat "$f"); repo=$(cat "$PIPE/orch-$n.repo" 2>/dev/null || echo "?")
      if kill -0 "$pid" 2>/dev/null; then state="running (pid $pid)"
      elif [ -f "$PIPE/orch-$n.stopped" ]; then state="stopped (manual)"
      elif [ -f "$PIPE/orch-$n.held" ]; then state="held (needs JP)"
      elif [ -f "$PIPE/orch-$n.done" ]; then state="done"
      else state="exited (will auto-restart)"; fi
      last=$( (cd "$repo" 2>/dev/null && gh issue view "$n" --json comments \
        --jq '[.comments[] | .body | split("\n")[0] | select(test("^\\*\\*\\[[a-z-]+\\] ") and (test("^\\*\\*\\[[a-z-]+\\] NOTE") | not))] | last // "none"') 2>/dev/null || echo "?")
      echo "#$n  $state  repo=$repo  latest marker: $last  log=$PIPE/orch-$n.log"
    done
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
      kill "$pid" && echo "stopped orchestrator for #$2 (pid $pid)"
    else
      echo "orchestrator for #$2 not running"
    fi
    touch "$PIPE/orch-$2.stopped"
    rm -f "$QUEUE/orch-$2.json"
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
    # Launching consumes agent-go: the VM's dispatch cron (~/.claude/pipeline/dispatch.sh) launches every open
    # agent-go issue it can see, with only *its own* /tmp/pipeline as the running-check — so an issue launched on
    # the Mac that still carries agent-go would get a second orchestrator on the VM within 15 min. Restarts after
    # a crash are the local supervisor's job, not the label's. (2026-09-08)
    (cd "$REPO" && gh issue edit "$ISSUE" --add-label "agent-in-progress" --remove-label "agent-go" 2>/dev/null) || true
    # Clear tombstones and restart state on manual launch
    rm -f "$PIPE/orch-$ISSUE".{stopped,held,done,alert} "$PIPE/orch-$ISSUE.restarts"
    if ! has_capacity; then
      python3 -c "
import json, datetime, time
with open('$QUEUE/orch-$ISSUE.json', 'w') as f:
    json.dump({'issue': '$ISSUE', 'repo': '$REPO', 'extra': '''$EXTRA''', 'reason': 'queued',
               'queued_at': datetime.datetime.utcnow().strftime('%FT%TZ'), 'not_before': int(time.time())}, f)
"
      echo "queued #$ISSUE ($(count_running)/$MAX_CONCURRENT slots full, $(mem_available_mb)MB avail) — supervisor will auto-launch when a slot opens"
      echo "check: ~/.claude/skills/orchestrate/orchestrate.sh queue"
      exit 0
    fi
    PROMPT="Drive GitHub issue $OWNER_REPO#$ISSUE through the agent pipeline by calling Agent(subagent_type: \"orchestrator\", prompt: \"Drive $OWNER_REPO#$ISSUE through the pipeline. Repo: $REPO. Read the latest marker on the issue and continue from there.\"). Do NOT use orchestrate.sh or the orchestrate skill — you ARE the headless launcher; call Agent() directly. Call Agent() in the FOREGROUND and block on its result — never run_in_background, never a detached process, never a poller: if you return before the agent finishes, this headless session exits and the pipeline stalls (incidents #163 and #165, 2026-09-08). $EXTRA"
    printf '\n===== [%s] LAUNCH issue=%s reason=manual =====\n' "$(date -u +%FT%TZ)" "$ISSUE" >> "$PIPE/orch-$ISSUE.log"
    cd "$REPO"
    PIPELINE_HEADLESS=1 nohup $SETSID bash -c '
      echo 300 > /proc/self/oom_score_adj 2>/dev/null
      claude --dangerously-skip-permissions -p "$1"
      echo $? > "$2"
    ' _ "$PROMPT" "$PIPE/orch-$ISSUE.exit" >> "$PIPE/orch-$ISSUE.log" 2>&1 &
    echo $! > "$PIPE/orch-$ISSUE.pid"; echo "$REPO" > "$PIPE/orch-$ISSUE.repo"
    date -u +%FT%TZ > "$PIPE/orch-$ISSUE.start"; printf '%s' "$EXTRA" > "$PIPE/orch-$ISSUE.extra"
    echo "launched orchestrator for $OWNER_REPO#$ISSUE  pid=$!  log=$PIPE/orch-$ISSUE.log"
    echo "check: ~/.claude/skills/orchestrate/orchestrate.sh status $ISSUE"
    ;;
esac

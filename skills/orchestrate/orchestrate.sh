#!/bin/bash
# Launch the pipeline orchestrator as a detached headless Claude Code process.
# Usage:
#   orchestrate.sh <repo-path> <issue> [extra instructions...]   launch (queues if at max)
#   orchestrate.sh status [issue]                                 list running/queued orchestrators
#   orchestrate.sh tail <issue> [lines]                           tail an orchestrator's log
#   orchestrate.sh stop <issue>                                   kill an orchestrator
#   orchestrate.sh queue                                          show the queue
set -euo pipefail
PIPE=/tmp/pipeline
QUEUE="$PIPE/queue"
mkdir -p "$PIPE" "$QUEUE"
MAX_CONCURRENT=3

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid; do
    [ -e "$f" ] || break
    kill -0 "$(cat "$f")" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

drain_queue() {
  for qf in $(ls -1 "$QUEUE"/*.json 2>/dev/null | sort -t- -k2 -n); do
    [ -e "$qf" ] || break
    local running
    running=$(count_running)
    [ "$running" -ge "$MAX_CONCURRENT" ] && break
    local q_issue q_repo q_extra
    q_issue=$(python3 -c "import json,sys; d=json.load(open('$qf')); print(d['issue'])")
    q_repo=$(python3 -c "import json,sys; d=json.load(open('$qf')); print(d['repo'])")
    q_extra=$(python3 -c "import json,sys; d=json.load(open('$qf')); print(d.get('extra',''))")
    if [ -f "$PIPE/orch-$q_issue.pid" ] && kill -0 "$(cat "$PIPE/orch-$q_issue.pid")" 2>/dev/null; then
      rm -f "$qf"
      continue
    fi
    local q_owner_repo
    q_owner_repo=$(cd "$q_repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")
    local prompt="Drive GitHub issue $q_owner_repo#$q_issue through the agent pipeline by calling Agent(subagent_type: \"orchestrator\", prompt: \"Drive $q_owner_repo#$q_issue through the pipeline. Repo: $q_repo. Read the latest marker on the issue and continue from there.\"). Do NOT use orchestrate.sh or the orchestrate skill — you ARE the headless launcher; call Agent() directly. $q_extra"
    cd "$q_repo"
    PIPELINE_HEADLESS=1 nohup claude --dangerously-skip-permissions -p "$prompt" > "$PIPE/orch-$q_issue.log" 2>&1 &
    echo $! > "$PIPE/orch-$q_issue.pid"; echo "$q_repo" > "$PIPE/orch-$q_issue.repo"; date -u +%FT%TZ > "$PIPE/orch-$q_issue.start"
    rm -f "$qf"
    echo "[queue-drain] launched #$q_issue (pid $!) — was queued" >> "$PIPE/queue-drain.log"
  done
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
      if kill -0 "$pid" 2>/dev/null; then state="running (pid $pid)"; else state="exited"; fi
      last=$( (cd "$repo" 2>/dev/null && gh issue view "$n" --json comments \
        --jq '[.comments[] | .body | split("\n")[0] | select(test("^\\*\\*\\[[a-z-]+\\] ") and (test("^\\*\\*\\[[a-z-]+\\] NOTE") | not))] | last // "none"') 2>/dev/null || echo "?")
      echo "#$n  $state  repo=$repo  latest marker: $last  log=$PIPE/orch-$n.log"
    done
    if ls "$QUEUE"/*.json >/dev/null 2>&1; then
      echo "--- queued ---"
      for qf in $(ls -1 "$QUEUE"/*.json 2>/dev/null | sort -t- -k2 -n); do
        q_issue=$(python3 -c "import json; d=json.load(open('$qf')); print(d['issue'])")
        q_repo=$(python3 -c "import json; d=json.load(open('$qf')); print(d['repo'])")
        queued_at=$(python3 -c "import json; d=json.load(open('$qf')); print(d.get('queued_at','?'))")
        echo "#$q_issue  queued since $queued_at  repo=$q_repo"
      done
    fi
    ;;
  tail)
    tail -n "${3:-20}" "$PIPE/orch-$2.log"
    ;;
  stop)
    pid=$(cat "$PIPE/orch-$2.pid"); kill "$pid" && echo "stopped orchestrator for #$2 (pid $pid)"
    drain_queue
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
    running=$(count_running)
    if [ "$running" -ge "$MAX_CONCURRENT" ]; then
      python3 -c "
import json, datetime
with open('$QUEUE/orch-$ISSUE.json', 'w') as f:
    json.dump({'issue': '$ISSUE', 'repo': '$REPO', 'extra': '''$EXTRA''', 'queued_at': datetime.datetime.utcnow().strftime('%FT%TZ')}, f)
"
      echo "queued #$ISSUE ($running/$MAX_CONCURRENT slots full) — will auto-launch when a slot opens"
      echo "check: ~/.claude/skills/orchestrate/orchestrate.sh queue"
      if ! pgrep -f "queue-drain.sh" >/dev/null 2>&1; then
        nohup bash "$(dirname "$0")/queue-drain.sh" >> "$PIPE/queue-drain.log" 2>&1 &
        echo "started queue-drain poller (pid $!)"
      fi
      exit 0
    fi
    PROMPT="Drive GitHub issue $OWNER_REPO#$ISSUE through the agent pipeline by calling Agent(subagent_type: \"orchestrator\", prompt: \"Drive $OWNER_REPO#$ISSUE through the pipeline. Repo: $REPO. Read the latest marker on the issue and continue from there.\"). Do NOT use orchestrate.sh or the orchestrate skill — you ARE the headless launcher; call Agent() directly. $EXTRA"
    cd "$REPO"
    PIPELINE_HEADLESS=1 nohup claude --dangerously-skip-permissions -p "$PROMPT" > "$PIPE/orch-$ISSUE.log" 2>&1 &
    echo $! > "$PIPE/orch-$ISSUE.pid"; echo "$REPO" > "$PIPE/orch-$ISSUE.repo"; date -u +%FT%TZ > "$PIPE/orch-$ISSUE.start"
    echo "launched orchestrator for $OWNER_REPO#$ISSUE  pid=$!  log=$PIPE/orch-$ISSUE.log"
    echo "check: ~/.claude/skills/orchestrate/orchestrate.sh status $ISSUE"
    drain_queue
    ;;
esac

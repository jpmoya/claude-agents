#!/bin/bash
# Lightweight poller: checks every 60s if a queue slot opened and launches the next queued orchestrator.
# Started automatically by orchestrate.sh when something is queued. Exits when the queue is empty.
set -euo pipefail
PIPE=/tmp/pipeline
QUEUE="$PIPE/queue"
MAX_CONCURRENT=3

while true; do
  sleep 60
  ls "$QUEUE"/*.json >/dev/null 2>&1 || { echo "[queue-drain] queue empty, exiting" >> "$PIPE/queue-drain.log"; exit 0; }
  running=0
  for f in "$PIPE"/orch-*.pid; do
    [ -e "$f" ] || break
    kill -0 "$(cat "$f")" 2>/dev/null && running=$((running + 1))
  done
  [ "$running" -ge "$MAX_CONCURRENT" ] && continue
  for qf in $(ls -1 "$QUEUE"/*.json 2>/dev/null | sort -t- -k2 -n); do
    [ -e "$qf" ] || break
    [ "$running" -ge "$MAX_CONCURRENT" ] && break
    q_issue=$(python3 -c "import json; d=json.load(open('$qf')); print(d['issue'])")
    q_repo=$(python3 -c "import json; d=json.load(open('$qf')); print(d['repo'])")
    q_extra=$(python3 -c "import json; d=json.load(open('$qf')); print(d.get('extra',''))")
    if [ -f "$PIPE/orch-$q_issue.pid" ] && kill -0 "$(cat "$PIPE/orch-$q_issue.pid")" 2>/dev/null; then
      rm -f "$qf"
      continue
    fi
    q_owner_repo=$(cd "$q_repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")
    prompt="Drive GitHub issue $q_owner_repo#$q_issue through the agent pipeline by calling Agent(subagent_type: \"orchestrator\", prompt: \"Drive $q_owner_repo#$q_issue through the pipeline. Repo: $q_repo. Read the latest marker on the issue and continue from there.\"). Do NOT use orchestrate.sh or the orchestrate skill — you ARE the headless launcher; call Agent() directly. $q_extra"
    cd "$q_repo"
    PIPELINE_HEADLESS=1 nohup claude --dangerously-skip-permissions -p "$prompt" > "$PIPE/orch-$q_issue.log" 2>&1 &
    echo $! > "$PIPE/orch-$q_issue.pid"; echo "$q_repo" > "$PIPE/orch-$q_issue.repo"; date -u +%FT%TZ > "$PIPE/orch-$q_issue.start"
    rm -f "$qf"
    running=$((running + 1))
    echo "[$(date -u +%FT%TZ)] launched #$q_issue (pid $!) from queue" >> "$PIPE/queue-drain.log"
  done
done

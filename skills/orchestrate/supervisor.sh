#!/bin/bash
# Stateless supervisor tick. Cron runs this every 2 min under flock.
# Detects exited non-terminal orchestrators and restarts them with backoff.
# Also drains the launch queue. One launch per tick max.
set -uo pipefail

PIPE=/tmp/pipeline
QUEUE="$PIPE/queue"
LOGDIR="$HOME/logs/pipeline"
SLOG="$LOGDIR/supervisor.log"
mkdir -p "$PIPE" "$QUEUE" "$LOGDIR"

MAX_CONCURRENT=3
MEM_FLOOR_MB=1200
MAX_NO_PROGRESS=3
MAX_TOTAL=6
BACKOFF=(120 300 900 1800)

export PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"

slog() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SLOG"; }

# Acquire lock — exit if previous tick still running
exec 9>"$PIPE/supervisor.lock"
flock -n 9 || exit 0

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid; do
    [ -e "$f" ] || break
    kill -0 "$(cat "$f")" 2>/dev/null && n=$((n + 1))
  done
  echo "$n"
}

mem_available_mb() { awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo; }

has_capacity() {
  [ "$(count_running)" -lt "$MAX_CONCURRENT" ] && [ "$(mem_available_mb)" -ge "$MEM_FLOOR_MB" ]
}

latest_marker() {
  local repo=$1 issue=$2
  (cd "$repo" 2>/dev/null && gh issue view "$issue" --json comments \
    --jq '[.comments[] | .body | split("\n")[0] | select(test("^\\*\\*\\[[a-z-]+\\] ") and (test("^\\*\\*\\[[a-z-]+\\] NOTE") | not))] | last // "none"') 2>/dev/null || echo "?"
}

issue_is_closed() {
  local repo=$1 issue=$2
  local state
  state=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json state --jq .state 2>/dev/null) || return 1
  [ "$state" = "CLOSED" ]
}

is_terminal() {
  local marker=$1
  [[ "$marker" =~ \]\ DEPLOYED ]] || [[ "$marker" =~ \]\ BLOCKED ]]
}

do_launch() {
  local repo=$1 issue=$2 extra=$3 restart_n=${4:-0} reason=${5:-manual}
  local owner_repo prompt preamble=""

  owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")

  if [ "$restart_n" -gt 0 ]; then
    preamble="AUTO-RESTART #$restart_n: a previous orchestrator process exited without reaching a terminal state. Verify branch/PR/comment state with gh before dispatching anything. Never redo a completed stage. "
  fi

  prompt="Drive GitHub issue $owner_repo#$issue through the agent pipeline by calling Agent(subagent_type: \"orchestrator\", prompt: \"Drive $owner_repo#$issue through the pipeline. Repo: $repo. Read the latest marker on the issue and continue from there. ${preamble}${extra}\"). Do NOT use orchestrate.sh or the orchestrate skill — you ARE the headless launcher; call Agent() directly. $extra"

  cd "$repo"
  PIPELINE_HEADLESS=1 nohup setsid bash -c '
    echo 300 > /proc/self/oom_score_adj 2>/dev/null
    claude --dangerously-skip-permissions -p "$1"
    echo $? > "$2"
  ' _ "$prompt" "$PIPE/orch-$issue.exit" > "$PIPE/orch-$issue.log" 2>&1 9>&- &

  echo $! > "$PIPE/orch-$issue.pid"
  echo "$repo" > "$PIPE/orch-$issue.repo"
  date -u +%FT%TZ > "$PIPE/orch-$issue.start"

  slog "[launch] #$issue pid=$! reason=$reason restart=$restart_n mem=$(mem_available_mb)MB running=$(count_running)/$MAX_CONCURRENT"
}

escalate() {
  local repo=$1 issue=$2 restarts_file=$3
  local owner_repo history_text exit_code

  owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")
  history_text=$(python3 -c "
import json, sys
try:
    d = json.load(open('$restarts_file'))
    for h in d.get('history', []):
        print(f\"| {h.get('ts','?')} | exit {h.get('exit','?')} | {h.get('marker','?')} |\")
except: pass
" 2>/dev/null)

  (cd "$repo" && gh issue comment "$issue" --body "$(cat <<EOF
**[supervisor] NOTE**

This orchestrator has been auto-restarted multiple times without making progress. Pausing automatic restarts — manual intervention needed.

| Time | Exit | Marker |
|---|---|---|
$history_text

Relaunch manually with \`orchestrate.sh $repo $issue\` after investigating.
EOF
)") 2>/dev/null

  touch "$PIPE/orch-$issue.held"
  slog "[escalate] #$issue — too many restarts without progress"
}

# --- Main tick ---

launched=0

# 1. Check each recorded orchestrator
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  issue=$(basename "$f" .pid); issue=${issue#orch-}
  pid=$(cat "$f")
  repo=$(cat "$PIPE/orch-$issue.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue

  # Skip if alive
  kill -0 "$pid" 2>/dev/null && continue

  # Skip if tombstoned
  [ -f "$PIPE/orch-$issue.stopped" ] && continue
  [ -f "$PIPE/orch-$issue.held" ] && continue
  [ -f "$PIPE/orch-$issue.done" ] && continue

  # Check if terminal
  if issue_is_closed "$repo" "$issue"; then
    touch "$PIPE/orch-$issue.done"
    slog "[done] #$issue — issue closed"
    continue
  fi

  marker=$(latest_marker "$repo" "$issue")
  if is_terminal "$marker"; then
    touch "$PIPE/orch-$issue.done"
    slog "[done] #$issue — terminal marker: $marker"
    continue
  fi

  # Non-terminal exit — potential restart
  [ "$launched" -ge 1 ] && continue  # one launch per tick

  restarts_file="$PIPE/orch-$issue.restarts"
  exit_code=$(cat "$PIPE/orch-$issue.exit" 2>/dev/null || echo "?")
  extra=$(cat "$PIPE/orch-$issue.extra" 2>/dev/null || echo "")

  # Load or init restart state
  if [ -f "$restarts_file" ]; then
    count=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('count',0))" 2>/dev/null || echo 0)
    total=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('total',0))" 2>/dev/null || echo 0)
    last_marker=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('last_marker',''))" 2>/dev/null || echo "")
  else
    count=0; total=0; last_marker=""
  fi

  # Check if marker progressed (reset no-progress counter)
  if [ "$marker" != "$last_marker" ] && [ -n "$last_marker" ]; then
    count=0
    slog "[progress] #$issue marker advanced: $last_marker -> $marker"
  fi

  count=$((count + 1))
  total=$((total + 1))

  # Check caps
  if [ "$count" -ge "$MAX_NO_PROGRESS" ] || [ "$total" -ge "$MAX_TOTAL" ]; then
    # Update history before escalating
    python3 -c "
import json, datetime
try: d = json.load(open('$restarts_file'))
except: d = {'count':0,'total':0,'last_marker':'','history':[]}
d['history'].append({'ts':'$(date -u +%FT%TZ)','exit':'$exit_code','marker':'''$marker'''})
d['count']=$count; d['total']=$total; d['last_marker']='''$marker'''
json.dump(d, open('$restarts_file','w'))
" 2>/dev/null
    escalate "$repo" "$issue" "$restarts_file"
    continue
  fi

  # Calculate backoff
  idx=$((count - 1))
  [ "$idx" -ge "${#BACKOFF[@]}" ] && idx=$(( ${#BACKOFF[@]} - 1 ))
  not_before=$(( $(date +%s) + ${BACKOFF[$idx]} ))

  # Update restart state
  python3 -c "
import json
try: d = json.load(open('$restarts_file'))
except: d = {'count':0,'total':0,'last_marker':'','history':[]}
d['history'].append({'ts':'$(date -u +%FT%TZ)','exit':'$exit_code','marker':'''$marker'''})
d['count']=$count; d['total']=$total; d['last_marker']='''$marker'''
json.dump(d, open('$restarts_file','w'))
" 2>/dev/null

  # Enqueue with backoff
  python3 -c "
import json
json.dump({'issue':'$issue','repo':'$repo','extra':'''$extra''','reason':'auto-restart','queued_at':'$(date -u +%FT%TZ)','not_before':$not_before}, open('$QUEUE/orch-$issue.json','w'))
" 2>/dev/null

  slog "[queue-restart] #$issue exit=$exit_code marker='$marker' count=$count/$MAX_NO_PROGRESS total=$total/$MAX_TOTAL backoff=${BACKOFF[$idx]}s"
done

# 2. Drain queue (one item per tick)
if [ "$launched" -eq 0 ] && has_capacity; then
  now_epoch=$(date +%s)
  best_qf=""
  best_issue=""

  for qf in "$QUEUE"/orch-*.json; do
    [ -e "$qf" ] || break
    not_before=$(python3 -c "import json; print(json.load(open('$qf')).get('not_before',0))" 2>/dev/null || echo 0)
    [ "$now_epoch" -lt "$not_before" ] && continue

    q_issue=$(python3 -c "import json; print(json.load(open('$qf'))['issue'])" 2>/dev/null)
    # Skip if already running
    if [ -f "$PIPE/orch-$q_issue.pid" ] && kill -0 "$(cat "$PIPE/orch-$q_issue.pid")" 2>/dev/null; then
      rm -f "$qf"
      continue
    fi

    best_qf="$qf"
    best_issue="$q_issue"
    break  # take first eligible
  done

  if [ -n "$best_qf" ]; then
    q_repo=$(python3 -c "import json; print(json.load(open('$best_qf'))['repo'])" 2>/dev/null)
    q_extra=$(python3 -c "import json; print(json.load(open('$best_qf')).get('extra',''))" 2>/dev/null)
    q_reason=$(python3 -c "import json; print(json.load(open('$best_qf')).get('reason','queued'))" 2>/dev/null)
    restart_n=0
    if [ "$q_reason" = "auto-restart" ] && [ -f "$PIPE/orch-$best_issue.restarts" ]; then
      restart_n=$(python3 -c "import json; print(json.load(open('$PIPE/orch-$best_issue.restarts')).get('count',0))" 2>/dev/null || echo 0)
    fi

    do_launch "$q_repo" "$best_issue" "$q_extra" "$restart_n" "$q_reason"
    rm -f "$best_qf"
    launched=1
  fi
fi

# Close lock (fd 9 closed on exit anyway, but be explicit)
exec 9>&-

#!/bin/bash
# Stateless supervisor tick — cron runs it every 2 min (VM even minutes, Mac odd minutes). One tick does, in order:
#   1. restart exited non-terminal local orchestrators with backoff
#   2. drain the local launch queue
#   3. label lifecycle: drop agent-in-progress on issues this machine finished or parked
#   4. shared dispatch: launch one agent-go issue from DISPATCH_REPOS after winning a claim
# One launch per tick max. All state is local (/tmp/pipeline); the only shared state is the issue's markers and labels.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there
SLOG="$LOGDIR/supervisor.log"
HOST=$(hostname -s)
mkdir -p "$PIPE" "$QUEUE" "$LOGDIR"

slog() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SLOG"; }

# Acquire lock — exit if previous tick still running
if command -v flock >/dev/null 2>&1; then
  exec 9>"$PIPE/supervisor.lock"
  flock -n 9 || exit 0
else
  # macOS has no flock: mkdir is atomic; a lock older than 10 min is a dead tick, reclaim it
  LOCKDIR="$PIPE/supervisor.lockdir"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then rmdir "$LOCKDIR" 2>/dev/null; mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else exit 0; fi
  fi
  trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT
fi

to_epoch() {  # ISO-8601 UTC → epoch; portable (macOS date has no -d)
  python3 -c "import sys,datetime; print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$1" 2>/dev/null || echo 0
}

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

power_ok() {  # Mac: dispatch new work only on AC power (a sleeping laptop strands claimed issues). Linux: always.
  [ "$(uname)" = "Darwin" ] || return 0
  pmset -g batt 2>/dev/null | grep -q "AC Power"
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

# terminal_kind <marker> <issue> → prints "done" / "gate" / "" (not terminal)
terminal_kind() {
  local marker=$1 issue=${2:-}
  [[ "$marker" =~ \]\ (DEPLOYED|APPLIED)$ ]] && { echo done; return; }
  [[ "$marker" =~ \]\ (MOCKUPS\ PENDING\ APPROVAL|AWAITING\ GO|EFFORT\ APPROVAL\ NEEDED)$ ]] && { echo gate; return; }
  if [[ "$marker" =~ \]\ BLOCKED ]]; then
    # BLOCKED gets a grace period — false BLOCKEDs from subagent races resolve within minutes
    if [ -n "$issue" ] && [ -f "$PIPE/orch-$issue.start" ]; then
      local age=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$issue.start")") ))
      if [ "$age" -lt "$GRACE_PERIOD_SECS" ]; then
        slog "[grace] #$issue — BLOCKED marker seen but run is ${age}s old (<${GRACE_PERIOD_SECS}s), waiting"
        echo ""; return
      fi
    fi
    echo gate; return
  fi
  echo ""
}

clear_in_progress() {  # idempotent; one gh call per issue, remembered in a marker file
  local repo=$1 issue=$2 why=$3
  [ -f "$PIPE/orch-$issue.label-cleared" ] && return 0
  if (cd "$repo" 2>/dev/null && gh issue edit "$issue" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1); then
    touch "$PIPE/orch-$issue.label-cleared"
    slog "[label] #$issue — removed $LABEL_IN_PROGRESS ($why)"
  fi
}

do_launch() {
  local repo=$1 issue=$2 extra=$3 restart_n=${4:-0} reason=${5:-manual}
  local owner_repo prompt preamble=""

  owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")

  if [ "$restart_n" -gt 0 ]; then
    preamble="AUTO-RESTART #$restart_n: a previous orchestrator process exited without reaching a terminal state. Verify branch/PR/comment state with gh before dispatching anything. Never redo a completed stage. "
  fi

  prompt="Drive GitHub issue $owner_repo#$issue through the agent pipeline by calling Agent(subagent_type: \"orchestrator\", prompt: \"Drive $owner_repo#$issue through the pipeline. Repo: $repo. Read the latest marker on the issue and continue from there. ${preamble}${extra}\"). Do NOT use orchestrate.sh or the orchestrate skill — you ARE the headless launcher; call Agent() directly. Call Agent() in the FOREGROUND and block on its result — never run_in_background, never a detached process, never a poller: if you return before the agent finishes, this headless session exits and the pipeline stalls (incidents #163 and #165, 2026-09-08). $extra"

  printf '\n===== [%s] LAUNCH issue=%s reason=%s restart=%s =====\n' "$(date -u +%FT%TZ)" "$issue" "$reason" "$restart_n" >> "$PIPE/orch-$issue.log"
  cd "$repo"
  PIPELINE_HEADLESS=1 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup $SETSID bash -c '
    echo 300 > /proc/self/oom_score_adj 2>/dev/null
    claude --dangerously-skip-permissions -p "$1"
    echo $? > "$2"
  ' _ "$prompt" "$PIPE/orch-$issue.exit" >> "$PIPE/orch-$issue.log" 2>&1 9>&- &

  echo $! > "$PIPE/orch-$issue.pid"
  echo "$repo" > "$PIPE/orch-$issue.repo"
  date -u +%FT%TZ > "$PIPE/orch-$issue.start"
  rm -f "$PIPE/orch-$issue.label-cleared"

  slog "[launch] #$issue pid=$! reason=$reason restart=$restart_n mem=$(mem_available_mb)MB running=$(count_running)/$MAX_CONCURRENT"
}

escalate() {
  local repo=$1 issue=$2 restarts_file=$3
  local owner_repo history_text

  owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")
  history_text=$(python3 -c "
import json, sys
try:
    d = json.load(open('$restarts_file'))
    for h in d.get('history', []):
        print(f\"| {h.get('ts','?')} | exit {h.get('exit','?')} | {h.get('marker','?')} |\")
except: pass
" 2>/dev/null)

  (cd "$repo" && gh issue comment "$issue" --body "$(cat <<EOC
**[supervisor] NOTE**

This orchestrator has been auto-restarted multiple times without making progress. Pausing automatic restarts — manual intervention needed.

| Time | Exit | Marker |
|---|---|---|
$history_text

Relaunch manually with \`orchestrate.sh $repo $issue\` after investigating.
EOC
)") 2>/dev/null

  touch "$PIPE/orch-$issue.held"
  rm -f "$QUEUE/orch-$issue.json"
  printf '%s Pipeline #%s held — needs manual relaunch after investigation (%s)\n' "$(date -u +%FT%TZ)" "$issue" "$owner_repo" > "$PIPE/orch-$issue.alert"
  slog "[escalate] #$issue — too many restarts without progress (queue entry purged)"
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
  case "$(terminal_kind "$marker" "$issue")" in
    done)
      touch "$PIPE/orch-$issue.done"
      slog "[done] #$issue — terminal marker: $marker"
      continue ;;
    gate)
      # Human gate (mockups, infra go, BLOCKED): park it; JP relaunches (or re-adds agent-go) after acting
      touch "$PIPE/orch-$issue.held"
      rm -f "$QUEUE/orch-$issue.json"
      printf '%s Pipeline #%s waiting on JP — %s; relaunch (or re-add %s) after acting\n' "$(date -u +%FT%TZ)" "$issue" "$marker" "$LABEL_GO" > "$PIPE/orch-$issue.alert"
      slog "[held] #$issue — waiting on JP: $marker"
      continue ;;
  esac

  # Non-terminal exit — potential restart
  [ "$launched" -ge 1 ] && continue  # one launch per tick

  restarts_file="$PIPE/orch-$issue.restarts"
  exit_code=$(cat "$PIPE/orch-$issue.exit" 2>/dev/null || echo "?")
  extra=$(cat "$PIPE/orch-$issue.extra" 2>/dev/null || echo "")

  # Detect transient exit: if the run was short-lived, it's likely a rate limit or OOM, not a real stall
  run_duration=0
  if [ -f "$PIPE/orch-$issue.start" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$issue.start")") ))
  fi
  transient=false
  [ "$run_duration" -lt "$MIN_RUN_SECS" ] && transient=true

  # Load or init restart state
  if [ -f "$restarts_file" ]; then
    count=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('count',0))" 2>/dev/null || echo 0)
    total=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('total',0))" 2>/dev/null || echo 0)
    transient_count=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('transient_count',0))" 2>/dev/null || echo 0)
    last_marker=$(python3 -c "import json; print(json.load(open('$restarts_file')).get('last_marker',''))" 2>/dev/null || echo "")
  else
    count=0; total=0; transient_count=0; last_marker=""
  fi

  # Check if marker progressed (reset no-progress counter)
  if [ "$marker" != "$last_marker" ] && [ -n "$last_marker" ]; then
    count=0
    slog "[progress] #$issue marker advanced: $last_marker -> $marker"
  fi

  total=$((total + 1))
  if $transient; then
    transient_count=$((transient_count + 1))
    slog "[transient] #$issue ran ${run_duration}s (<${MIN_RUN_SECS}s) — treating as transient (${transient_count}/${MAX_TRANSIENT_TOTAL})"
  else
    count=$((count + 1))
  fi

  # Check caps — transient exits have a much higher ceiling
  should_escalate=false
  if $transient; then
    [ "$transient_count" -ge "$MAX_TRANSIENT_TOTAL" ] && should_escalate=true
  else
    if [ "$count" -ge "$MAX_NO_PROGRESS" ] || [ "$total" -ge "$MAX_TOTAL" ]; then
      should_escalate=true
    fi
  fi

  python3 -c "
import json
try: d = json.load(open('$restarts_file'))
except: d = {'count':0,'total':0,'transient_count':0,'last_marker':'','history':[]}
d['history'].append({'ts':'$(date -u +%FT%TZ)','exit':'$exit_code','marker':'''$marker''','transient':$($transient && echo True || echo False),'run_secs':$run_duration})
d['count']=$count; d['total']=$total; d['transient_count']=$transient_count; d['last_marker']='''$marker'''
json.dump(d, open('$restarts_file','w'))
" 2>/dev/null

  if $should_escalate; then
    escalate "$repo" "$issue" "$restarts_file"
    continue
  fi

  # Already queued — don't overwrite its not_before
  if [ -f "$QUEUE/orch-$issue.json" ]; then
    slog "[queue-wait] #$issue — already queued, skipping re-enqueue"
    continue
  fi

  # Calculate backoff — transient exits use longer backoff
  if $transient; then
    idx=$((transient_count - 1))
    [ "$idx" -ge "${#TRANSIENT_BACKOFF[@]}" ] && idx=$(( ${#TRANSIENT_BACKOFF[@]} - 1 ))
    backoff_val=${TRANSIENT_BACKOFF[$idx]}
  else
    idx=$((count - 1))
    [ "$idx" -ge "${#BACKOFF[@]}" ] && idx=$(( ${#BACKOFF[@]} - 1 ))
    backoff_val=${BACKOFF[$idx]}
  fi
  not_before=$(( $(date +%s) + backoff_val ))

  # Enqueue with backoff
  python3 -c "
import json
json.dump({'issue':'$issue','repo':'$repo','extra':'''$extra''','reason':'auto-restart','queued_at':'$(date -u +%FT%TZ)','not_before':$not_before}, open('$QUEUE/orch-$issue.json','w'))
" 2>/dev/null

  slog "[queue-restart] #$issue exit=$exit_code marker='$marker' transient=$transient run=${run_duration}s count=$count/$MAX_NO_PROGRESS transient=$transient_count/$MAX_TRANSIENT_TOTAL total=$total backoff=${backoff_val}s"
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
    # Skip if tombstoned (stopped, held, or done)
    if [ -f "$PIPE/orch-$q_issue.stopped" ] || [ -f "$PIPE/orch-$q_issue.held" ] || [ -f "$PIPE/orch-$q_issue.done" ]; then
      rm -f "$qf"
      slog "[drain-skip] #$q_issue — tombstoned, purging queue entry"
      continue
    fi
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

# 3. Label lifecycle — agent-in-progress means "an orchestrator owns this somewhere"; drop it once this machine
#    finished (done), parked (held: gate or escalation), or JP stopped it. Alive/restarting runs keep it.
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  issue=$(basename "$f" .pid); issue=${issue#orch-}
  repo=$(cat "$PIPE/orch-$issue.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue
  kill -0 "$(cat "$f")" 2>/dev/null && continue
  if   [ -f "$PIPE/orch-$issue.done" ];    then clear_in_progress "$repo" "$issue" done
  elif [ -f "$PIPE/orch-$issue.held" ];    then clear_in_progress "$repo" "$issue" held
  elif [ -f "$PIPE/orch-$issue.stopped" ]; then clear_in_progress "$repo" "$issue" stopped
  fi
done

# 4. Shared dispatch — one agent-go issue per tick, claimed before launch so two machines never take the same one
if [ "$launched" -eq 0 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ]; then
  if ! power_ok; then
    slog "[dispatch] skipped — on battery power"
  elif ! has_capacity; then
    :  # nothing to log every 2 min; status shows the running set
  else
    now_epoch=$(date +%s)
    cutoff=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=$CLAIM_WINDOW_SECS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
    for entry in "${DISPATCH_REPOS[@]}"; do
      [ "$launched" -ge 1 ] && break
      owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
      if [ ! -d "$local_path/.git" ]; then slog "[dispatch] $owner_repo — no local checkout at $local_path, skipping"; continue; fi
      candidates=$(gh issue list --repo "$owner_repo" --state open --label "$LABEL_GO" --limit 50 --json number,labels \
        --jq ".[] | select([.labels[].name] | index(\"$LABEL_IN_PROGRESS\") | not) | .number" 2>/dev/null) || continue
      for num in $candidates; do
        # local state: alive or queued here → not a candidate
        if [ -f "$PIPE/orch-$num.pid" ] && kill -0 "$(cat "$PIPE/orch-$num.pid")" 2>/dev/null; then continue; fi
        [ -f "$QUEUE/orch-$num.json" ] && continue

        ts=$(date -u +%FT%TZ)
        (cd "$local_path" && gh issue comment "$num" --body "**[supervisor] NOTE** claim: $HOST $ts" >/dev/null 2>&1) || { slog "[dispatch] $owner_repo#$num — claim comment failed"; continue; }
        sleep "$CLAIM_SETTLE_SECS"
        winner=$(cd "$local_path" && gh issue view "$num" --json comments \
          --jq "[.comments[] | select(.body | startswith(\"**[supervisor] NOTE** claim: \")) | select(.createdAt > \"$cutoff\")] | sort_by(.createdAt) | first | .body" 2>/dev/null | awk '{print $4}')
        if [ "$winner" != "$HOST" ]; then
          slog "[dispatch] $owner_repo#$num — lost claim to ${winner:-?}"
          continue
        fi
        # Won: a re-dispatch is JP's explicit "go again", so clear local tombstones like a manual launch does.
        rm -f "$PIPE/orch-$num".{stopped,held,done,alert,label-cleared} "$PIPE/orch-$num.restarts"
        out=$("$(dirname "${BASH_SOURCE[0]}")/orchestrate.sh" --force "$local_path" "$num" 2>&1 | tail -1)
        slog "[dispatch] $owner_repo#$num — claimed by $HOST, $out"
        launched=1
        break
      done
    done
  fi
fi

exec 9>&- 2>/dev/null

#!/bin/bash
# Stateless supervisor tick — cron runs it every 2 min (VM even minutes, Mac odd minutes). One tick does, in order:
#   1. restart exited non-terminal local orchestrators with backoff
#   2. drain the local launch queue
#   3. label lifecycle: drop agent-in-progress on issues this machine finished, parked, or abandoned
#   4. label reconciliation: clear orphaned agent-in-progress labels (no local pid, no queue, stale marker)
#   5. shared dispatch: launch one agent-go issue from DISPATCH_REPOS after winning a claim
#   7. status reconcile: refresh listed tickets from GitHub (backgrounded, throttled to once per 600 s; issue #51)
# One launch per tick max. All state is local (/tmp/pipeline); the only shared state is the issue's markers and labels.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/config.sh"
# shared launcher helpers: SETSID probe, capacity checks, marker jq expression (issue #8)
source "$HERE/pipeline-lib.sh"
# shared run-state derivation + report_status_async (issue #10)
source "$HERE/run-state.sh"
# routing-marker vocabulary (marker_re), shared with the handoff hook and the orchestrator
source "$HERE/../../hooks/pipeline-markers.sh" 2>/dev/null || source "$HOME/.claude/hooks/pipeline-markers.sh"

SLOG="$LOGDIR/supervisor.log"
HOST=$(hostname -s)
mkdir -p "$PIPE" "$QUEUE" "$LOGDIR"

slog() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$SLOG"; }

# Event push: every tick, deliberately outside the single-flight lock below — this is the
# keep-alive + safety net (design #10 §4.4), so it must still fire even on a tick that skips
# because a previous one is still running.
report_status_async "tick"

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

power_ok() {  # Mac: dispatch new work only on AC power (a sleeping laptop strands claimed issues). Linux: always.
  [ "$(uname)" = "Darwin" ] || return 0
  pmset -g batt 2>/dev/null | grep -q "AC Power"
}

latest_marker() {  # the GATE marker: newest real routing marker whose agent is not project-manager (NOTEs and off-vocabulary lines are inert).
  # When the newest routing marker overall is a `[project-manager]` one (it follows the gate marker), it is printed on a 2nd line.
  # Both come out of the same single `gh issue view` call (claude-agents#59).
  local repo=$1 issue=$2 last
  last=$(marker_last_jq)
  (cd "$repo" 2>/dev/null && gh issue view "$issue" --json comments \
    --jq "($last) as \$last | ({comments: [.comments[] | select(.body | startswith(\"**[project-manager] \") | not)]} | $last) as \$gate | if \$last == \$gate then \$gate else \$gate + \"\\n\" + \$last end") 2>/dev/null || echo "?"
}

issue_is_closed() {
  local repo=$1 issue=$2
  local state
  state=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json state --jq .state 2>/dev/null) || return 1
  [ "$state" = "CLOSED" ]
}

# terminal_kind <gate marker> <issue> [<project-manager marker posted after it>] → prints "done" / "gate" /
# "grace" (BLOCKED inside the grace window: wait) / "" (not terminal). It judges the GATE marker. A later
# `[project-manager] DECISION` / `JP CONFIRMED` lifts exactly one gate — a code-track BLOCKED — so the run takes the
# normal restart path and the orchestrator validates and relays the decision. It never lifts MOCKUPS PENDING APPROVAL,
# AWAITING GO, EFFORT APPROVAL NEEDED or an infra-track BLOCKED: those stay with JP (claude-agents#59).
terminal_kind() {
  local marker=$1 issue=${2:-} decision=${3:-}
  marker=${marker%%\*\*}   # markers are bold ("**[deployer] DEPLOYED**"): strip the trailing bold so the $-anchors below match
  [[ "$marker" =~ \]\ (DEPLOYED|DEPLOYED\ TO\ STAGING|APPLIED)$ ]] && { echo done; return; }
  [[ "$marker" =~ \]\ (MOCKUPS\ PENDING\ APPROVAL|AWAITING\ GO|EFFORT\ APPROVAL\ NEEDED)$ ]] && { echo gate; return; }
  if [[ "$marker" =~ \]\ BLOCKED ]]; then
    # delegated decision recorded after a code-track BLOCKED: not a gate (infra-track BLOCKED stays one)
    if [ -n "$decision" ] && ! [[ "$marker" =~ ^\*\*\[infra- ]]; then echo ""; return; fi
    # BLOCKED gets a grace period — false BLOCKEDs from subagent races resolve within minutes
    if [ -n "$issue" ] && [ -f "$PIPE/orch-$issue.start" ]; then
      local age=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$issue.start")") ))
      if [ "$age" -lt "$GRACE_PERIOD_SECS" ]; then
        slog "[grace] #$issue — BLOCKED marker seen but run is ${age}s old (<${GRACE_PERIOD_SECS}s), waiting"
        echo grace; return
      fi
    fi
    echo gate; return
  fi
  echo ""
}

slack_thread_for() {  # <owner/repo> <issue> → "<channel> <ts>" from the last "**[pipeline-bridge] NOTE** slack-thread: <channel>:<ts>" comment, only if <channel> is $SLACK_ENGINEERING_CHANNEL; else nothing
  local owner_repo=$1 issue=$2 prefix line ch ts
  prefix='**[pipeline-bridge] NOTE** slack-thread: '
  line=$(gh issue view "$issue" --repo "$owner_repo" --json comments \
    --jq '[.comments[] | .body | split("\n")[0] | select(startswith("**[pipeline-bridge] NOTE** slack-thread: "))] | last // empty' 2>/dev/null) || return 0
  line=${line%$'\r'}
  [ -n "$line" ] || return 0
  line=${line#"$prefix"}
  ch=${line%%:*}
  ts=${line#*:}
  [ -n "$ch" ] && [ -n "$ts" ] && [ "$ch" != "$line" ] || return 0
  [ "$ch" = "${SLACK_ENGINEERING_CHANNEL:-}" ] || return 0
  printf '%s %s\n' "$ch" "$ts"
}

notify_engineering() {  # post a pipeline event to #engineering; requires SLACK_BOT_TOKEN + SLACK_ENGINEERING_CHANNEL
  local issue=$1 emoji=$2 reason=$3 owner_repo=$4
  [ -z "${SLACK_BOT_TOKEN:-}" ] || [ -z "${SLACK_ENGINEERING_CHANNEL:-}" ] && return 0
  local link="https://github.com/$owner_repo/issues/$issue"
  local msg="$emoji <$link|#$issue> — $reason"
  local payload thread thread_ts
  thread=$(slack_thread_for "$owner_repo" "$issue" 2>/dev/null) || thread=""
  thread_ts=${thread#* }
  if [ -n "$thread" ]; then
    payload=$(jq -n --arg ch "$SLACK_ENGINEERING_CHANNEL" --arg txt "$msg" --arg ts "$thread_ts" \
      '{channel: $ch, text: $txt, unfurl_links: false, thread_ts: $ts}')
  else
    payload=$(jq -n --arg ch "$SLACK_ENGINEERING_CHANNEL" --arg txt "$msg" \
      '{channel: $ch, text: $txt, unfurl_links: false}')
  fi
  local resp
  resp=$(curl -s --max-time 10 -X POST -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" -d "$payload" https://slack.com/api/chat.postMessage 2>/dev/null) || true
  if echo "$resp" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
    slog "[slack] #$issue — posted to engineering"
  else
    slog "[slack] #$issue — post failed: $(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo 'curl error')"
  fi
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
  local owner_repo prompt title preamble=""

  owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")

  # Ticket title for the status board (#29): orchestrate.sh normally wrote it at launch and restarts reuse that
  # file; fetch only when it is missing. A failed or empty fetch leaves no file and never blocks the launch.
  if [ ! -f "$PIPE/orch-$issue.title" ]; then
    title=$(cd "$repo" && gh issue view "$issue" --json title --jq .title 2>/dev/null) || title=""
    [ -n "$title" ] && printf '%s\n' "$title" > "$PIPE/orch-$issue.title"
  fi

  if [ "$restart_n" -gt 0 ]; then
    preamble="AUTO-RESTART #$restart_n: a previous orchestrator process exited without reaching a terminal state. Verify branch/PR/comment state with gh before dispatching anything. Never redo a completed stage. "
  fi

  # Same launch shape as orchestrate.sh: the headless session IS the orchestrator (--agent), no Agent() call.
  prompt="Drive $owner_repo#$issue through the pipeline. Repo: $repo. Read the latest marker on the issue and continue from there. ${preamble}${extra}"

  printf '\n===== [%s] LAUNCH issue=%s reason=%s restart=%s =====\n' "$(date -u +%FT%TZ)" "$issue" "$reason" "$restart_n" >> "$PIPE/orch-$issue.log"
  rm -f "$PIPE/orch-$issue.exit"   # a killed run never writes it; a stale value would be reported as this run's (#38)
  cd "$repo"
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup $SETSID bash -c '
    echo 300 > /proc/self/oom_score_adj 2>/dev/null
    claude --dangerously-skip-permissions --agent orchestrator -p "$1"
    echo $? > "$2"
  ' _ "$prompt" "$PIPE/orch-$issue.exit" >> "$PIPE/orch-$issue.log" 2>&1 9>&- &

  echo $! > "$PIPE/orch-$issue.pid"
  echo "$repo" > "$PIPE/orch-$issue.repo"
  [ -f "$PIPE/orch-$issue.start" ] || date -u +%FT%TZ > "$PIPE/orch-$issue.start"
  date -u +%FT%TZ > "$PIPE/orch-$issue.launched-at"
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
  report_status_async "escalate"   # event push: run held (design #10 §4.4)
  notify_engineering "$issue" ":rotating_light:" "Stalled — restarted multiple times without progress. Needs investigation." "$owner_repo"
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
  decision=""
  case "$marker" in *$'\n'*) decision=${marker#*$'\n'}; marker=${marker%%$'\n'*} ;; esac   # line 2 = [project-manager] marker after the gate marker
  case "$(terminal_kind "$marker" "$issue" "$decision")" in
    done)
      touch "$PIPE/orch-$issue.done"
      slog "[done] #$issue — terminal marker: $marker"
      notify_engineering "$issue" ":white_check_mark:" "Deployed" "$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")"
      continue ;;
    gate)
      # Human gate (mockups, infra go, BLOCKED with no delegated decision after it): park it; JP relaunches (or re-adds
      # agent-go) after acting. $marker is the gate marker, never a [project-manager] one. A run that is already .held is
      # skipped above and stays held — held runs are not polled; the project-manager relaunches with orchestrate.sh,
      # which clears .held (claude-agents#59).
      touch "$PIPE/orch-$issue.held"
      rm -f "$QUEUE/orch-$issue.json"
      printf '%s Pipeline #%s waiting on JP — %s; relaunch (or re-add %s) after acting\n' "$(date -u +%FT%TZ)" "$issue" "$marker" "$LABEL_GO" > "$PIPE/orch-$issue.alert"
      slog "[held] #$issue — waiting on JP: $marker"
      report_status_async "held"   # event push: run held/gate (design #10 §4.4)
      gate_reason=$(echo "$marker" | sed 's/\*\*\[[^]]*\]\*\* *//; s/^ *//; s/ *$//')
      [ -z "$gate_reason" ] && gate_reason="$marker"
      notify_engineering "$issue" ":hand:" "Waiting on you — $gate_reason" "$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")"
      continue ;;
    grace) continue ;;
  esac

  # Already queued — nothing ended this tick: don't count it, don't overwrite its not_before
  if [ -f "$QUEUE/orch-$issue.json" ]; then
    slog "[queue-wait] #$issue — already queued, skipping re-enqueue"
    continue
  fi

  # Non-terminal exit — potential restart
  [ "$launched" -ge 1 ] && continue  # one launch per tick

  restarts_file="$PIPE/orch-$issue.restarts"
  exit_code=$(cat "$PIPE/orch-$issue.exit" 2>/dev/null || echo "?")
  extra=$(cat "$PIPE/orch-$issue.extra" 2>/dev/null || echo "")

  # Detect transient exit: use per-launch timestamp (.launched-at), not the original .start
  # .start is preserved across restarts (used by BLOCKED grace window); .launched-at tracks this launch only
  run_duration=0
  if [ -f "$PIPE/orch-$issue.launched-at" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$issue.launched-at")") ))
  elif [ -f "$PIPE/orch-$issue.start" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/orch-$issue.start")") ))
  fi
  transient=false
  [ "$run_duration" -lt "$MIN_RUN_SECS" ] && transient=true

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
    total=0
    slog "[progress] #$issue marker advanced: $last_marker -> $marker"
  fi

  total=$((total + 1))
  if $transient; then
    slog "[transient] #$issue ran ${run_duration}s (<${MIN_RUN_SECS}s) — treating as transient"
  else
    count=$((count + 1))
  fi

  # One ceiling for every exit, fast or slow
  should_escalate=false
  if [ "$count" -ge "$MAX_NO_PROGRESS" ] || [ "$total" -ge "$MAX_TOTAL" ]; then
    should_escalate=true
  fi

  python3 -c "
import json
try: d = json.load(open('$restarts_file'))
except: d = {'count':0,'total':0,'last_marker':'','history':[]}
d['history'].append({'ts':'$(date -u +%FT%TZ)','exit':'$exit_code','marker':'''$marker''','transient':$($transient && echo True || echo False),'run_secs':$run_duration})
d['count']=$count; d['total']=$total; d['last_marker']='''$marker'''
json.dump(d, open('$restarts_file','w'))
" 2>/dev/null

  if $should_escalate; then
    escalate "$repo" "$issue" "$restarts_file"
    continue
  fi

  # Calculate backoff — transient exits use longer backoff
  if $transient; then
    idx=$((total - 1))
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

  slog "[queue-restart] #$issue exit=$exit_code marker='$marker' transient=$transient run=${run_duration}s count=$count/$MAX_NO_PROGRESS total=$total backoff=${backoff_val}s"
  report_status_async "queue-restart"   # event push: run exited -> requeued (design #10 §4.4)
done

# 2. Drain queue (one item per tick, oldest queued_at first)
# Capacity is decided once per tick; the drain and the dispatch step (5) share the result, so a slot freed
# mid-tick never goes to a new agent-go issue while a queued ticket waits.
HAS_CAP=0
has_capacity && HAS_CAP=1
if [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ]; then
  now_epoch=$(date +%s)
  best_qf=""
  best_issue=""
  best_key=""

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

    # Order key: queued_at epoch (fallback: file mtime when missing/unparseable), then issue number
    q_key=$(python3 -c "
import json, os, datetime
f='$qf'
try:
    t=datetime.datetime.strptime(json.load(open(f))['queued_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
except Exception:
    t=os.path.getmtime(f)
print('%d %d' % (int(t), int('$q_issue')))
" 2>/dev/null)
    [ -z "$q_key" ] && q_key="$(stat -c %Y "$qf" 2>/dev/null || stat -f %m "$qf") ${q_issue//[!0-9]/}"
    if [ -z "$best_qf" ] || python3 -c "import sys; a=tuple(map(int,'$q_key'.split())); b=tuple(map(int,'$best_key'.split())); sys.exit(0 if a<b else 1)"; then
      best_qf="$qf"
      best_issue="$q_issue"
      best_key="$q_key"
    fi
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
#    finished (done), parked (held: gate or escalation), stopped, or dead with no pending relaunch.
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  issue=$(basename "$f" .pid); issue=${issue#orch-}
  repo=$(cat "$PIPE/orch-$issue.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue
  kill -0 "$(cat "$f")" 2>/dev/null && continue
  if   [ -f "$PIPE/orch-$issue.done" ];    then clear_in_progress "$repo" "$issue" done
  elif [ -f "$PIPE/orch-$issue.held" ];    then clear_in_progress "$repo" "$issue" held
  elif [ -f "$PIPE/orch-$issue.stopped" ]; then clear_in_progress "$repo" "$issue" stopped
  elif [ ! -f "$QUEUE/orch-$issue.json" ]; then
    clear_in_progress "$repo" "$issue" "dead-no-queue"
    slog "[label] #$issue — process dead, no queue entry, cleared orphaned label"
  fi
done

# 4. Label reconciliation — catch orphaned agent-in-progress labels that have no local state at all
#    (e.g. /tmp was cleared, or a run from another machine died). Only clear if no marker movement for 30+ min.
STALE_LABEL_SECS=1800
if [ "${#DISPATCH_REPOS[@]}" -gt 0 ]; then
  for entry in "${DISPATCH_REPOS[@]}"; do
    owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
    [ -d "$local_path/.git" ] || continue
    orphans=$(gh issue list --repo "$owner_repo" --state open --label "$LABEL_IN_PROGRESS" --limit 50 --json number --jq '.[].number' 2>/dev/null) || continue
    for num in $orphans; do
      # Skip if we have a live process or queue entry
      if [ -f "$PIPE/orch-$num.pid" ] && kill -0 "$(cat "$PIPE/orch-$num.pid" 2>/dev/null)" 2>/dev/null; then continue; fi
      [ -f "$QUEUE/orch-$num.json" ] && continue
      # Check marker staleness — only clear if no movement for STALE_LABEL_SECS
      last_comment_age=$(cd "$local_path" && gh issue view "$num" --json comments \
        --jq '[.comments[-1].createdAt // empty] | if length > 0 then .[0] else "" end' 2>/dev/null)
      if [ -n "$last_comment_age" ]; then
        comment_epoch=$(to_epoch "$last_comment_age")
        age=$(( $(date +%s) - comment_epoch ))
        [ "$age" -lt "$STALE_LABEL_SECS" ] && continue
      fi
      (cd "$local_path" && gh issue edit "$num" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1) && \
        slog "[reconcile] $owner_repo#$num — cleared orphaned $LABEL_IN_PROGRESS (no local state, marker stale ${age:-?}s)"
    done
  done
fi

# 5 (was 4). Shared dispatch — one agent-go issue per tick, claimed before launch so two machines never take the same one
if [ "$launched" -eq 0 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ]; then
  if ! power_ok; then
    slog "[dispatch] skipped — on battery power"
  elif [ "$HAS_CAP" -ne 1 ]; then
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
        rm -f "$PIPE/orch-$num".{stopped,held,done,closed,marker,alert,label-cleared} "$PIPE/orch-$num.restarts"
        out=$("$(dirname "${BASH_SOURCE[0]}")/orchestrate.sh" --force "$local_path" "$num" 2>&1 | tail -1)
        slog "[dispatch] $owner_repo#$num — claimed by $HOST, $out"
        launched=1
        break
      done
    done
  fi
fi

# 6. Slack reply bridge — handled by openclaw's native Slack event routing (agent "pipeline-bridge"
#    in ~/.openclaw/agents/, binding in openclaw.json for #engineering, requireMention: true), not
#    by this supervisor tick. The relay's own logic is two tracked files in this repo:
#    skills/orchestrate/pipeline-bridge-dispatch.sh (deterministic resolve + agent-go dispatch) and
#    skills/orchestrate/pipeline-bridge-prompt.md (the relay's instructions — manually installed to
#    ~/.openclaw/agents/pipeline-bridge/agent/IDENTITY.md, outside this repo; see README.md).

# 7. Status reconcile (issue #51) — refresh every listed ticket from GitHub (closed -> Completed, latest marker).
#    Throttled inside the script (600 s/host); backgrounded with fd 9 closed like report_status_async, so a slow
#    or failing pass never delays or fails the tick.
( "$HERE/reconcile-status.sh" >/dev/null 2>&1 & ) 9>&- || true

exec 9>&- 2>/dev/null

#!/bin/bash
# Stateless supervisor tick — cron runs it every 2 min (VM even minutes, Mac odd minutes). One tick does, in order:
#   1. restart exited non-terminal local orchestrators with backoff
#   2. drain the local launch queue
#   3. label lifecycle: drop agent-in-progress on issues this machine finished, parked, or abandoned
#   4. label reconciliation: clear orphaned agent-in-progress labels (no local pid, no queue, stale marker)
#   3b. intake: triage one user-feedback-intake issue from DISPATCH_REPOS (claim, swap label, launch `--agent intake`)
#   3c. spec: PM-only spec run for one `user-feedback-needs-spec` idea from DISPATCH_REPOS (no agent-go, no orchestrator; ends in agent-proposed)
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
  # Exception (claude-agents#133): a pre-implementation `[test-reviewer] TESTS APPROVED` that is the newest one does not hide a
  # `[fullstack-developer]` BLOCKED / TEST DEFECT / IMPLEMENTED posted after the latest TESTS WRITTEN: that developer marker (the latest) is the gate marker.
  # When the newest routing marker overall is a `[project-manager]` one (it follows the gate marker), it is printed on a 2nd line.
  # Both come out of the same single `gh issue view` call (claude-agents#59).
  local repo=$1 issue=$2 last list prog
  last=$(marker_last_jq); list=${last% | last // \"none\"}   # list = the same expression minus its final `last`
  prog="($last) as \$last | {comments: [.comments[] | select(.body | startswith(\"**[project-manager] \") | not)]} as \$np
    | (\$np | $last) as \$g0 | (\$np | $list) as \$m | (\$m | length) as \$n | (\$m | to_entries) as \$e
    | ([\$e[] | select(.value | test(\"^\\\\*\\\\*\\\\[test-writer\\\\] TESTS WRITTEN\")) | .key] | last // -1) as \$w
    | ([\$e[] | select(.key > \$w and .key < \$n - 1 and (.value | test(\"^\\\\*\\\\*\\\\[fullstack-developer\\\\] (BLOCKED|TEST DEFECT|IMPLEMENTED)\"))) | .value] | last // null) as \$dev
    | (if (\$g0 | test(\"^\\\\*\\\\*\\\\[test-reviewer\\\\] TESTS APPROVED\")) and \$dev != null then \$dev else \$g0 end) as \$gate
    | if (\$last | startswith(\"**[project-manager] \") | not) then \$gate else \$gate + \"\\n\" + \$last end"
  (cd "$repo" 2>/dev/null && gh issue view "$issue" --json comments --jq "$prog") 2>/dev/null || echo "?"
}

issue_is_closed() {
  local repo=$1 issue=$2
  local state
  state=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json state --jq .state 2>/dev/null) || return 1
  [ "$state" = "CLOSED" ]
}

# #115 begin
# rejected_ok <repo dir> <issue> → 0 when the newest REJECTED is a real terminal outcome; otherwise logs it as inert (routing unchanged).
rejected_ok() {
  local repo=$1 issue=$2 why
  why=$(cd "$repo" 2>/dev/null && gh issue view "$issue" --json labels,comments 2>/dev/null | jq -r '
    ([.comments[].body | split("\n")] | map(select(.[0] | test("^\\*\\*\\[(product-manager|fullstack-developer)\\] REJECTED(\\*\\*|:| |$)"))) | last) as $r
    | if ([.labels[].name] | index("user-feedback") | not) then "no user-feedback label"
      elif $r == null then "no REJECTED from an allowed agent"
      elif ($r[1] // "" | rtrimstr("\r") | test("^Reason: (not-a-bug|cannot-reproduce|needs-spec|duplicate of #[0-9]+)$") | not) then "unknown or missing Reason"
      else "ok" end') || why="?"
  [ "$why" = ok ] && return 0
  slog "[rejected] #$issue — REJECTED marker inert: $why"; return 1
}
# #115 end
# "done" covers DEPLOYED / DEPLOYED TO STAGING / APPLIED and the architect's SPLIT (children run their own pipelines; #118).
# terminal_kind <gate marker> <issue> [<project-manager marker posted after it>] [<repo dir>] [<run key>] → prints "done" / "gate" /
# "grace" (BLOCKED inside the grace window: wait) / "" (not terminal). It judges the GATE marker. A later
# `[project-manager] DECISION` / `JP CONFIRMED` lifts exactly one gate — a code-track BLOCKED — so the run takes the
# normal restart path and the orchestrator validates and relays the decision. It never lifts MOCKUPS PENDING APPROVAL,
# AWAITING GO, EFFORT APPROVAL NEEDED or an infra-reviewer BLOCKED. An infra planner/operator BLOCKED is lifted only when
# infra_staging_only holds (staging-only ticket, no JP-only item; claude-agents#89); otherwise it stays with JP.
terminal_kind() {
  local marker=$1 issue=${2:-} decision=${3:-} repo=${4:-.} key=${5:-}
  marker=${marker%%\*\*}   # markers are bold ("**[deployer] DEPLOYED**"): strip the trailing bold so the $-anchors below match
  [[ "$marker" =~ \]\ (DEPLOYED|DEPLOYED\ TO\ STAGING|APPLIED|SPLIT)$ ]] && { echo done; return; }
  [[ "$marker" =~ \]\ REJECTED ]] && { rejected_ok "$repo" "$issue" && echo done || echo ""; return; }   # #115: valid only on user-feedback, from PM/developer, with a known Reason
  [[ "$marker" =~ \]\ (MOCKUPS\ PENDING\ APPROVAL|AWAITING\ GO|EFFORT\ APPROVAL\ NEEDED)$ ]] && { echo gate; return; }
  if [[ "$marker" =~ \]\ BLOCKED ]]; then
    # delegated decision recorded after a code-track BLOCKED: not a gate. An infra planner/operator BLOCKED is lifted
    # only when infra_staging_only succeeds (claude-agents#89); infra-reviewer BLOCKED always stays a gate.
    if [ -n "$decision" ]; then
      if ! [[ "$marker" =~ ^\*\*\[infra- ]]; then echo ""; return; fi
      if [[ "$marker" =~ ^\*\*\[infra-(planner|operator)\] ]]; then
        local orepo burl
        orepo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)
        burl=$(gh issue view "$issue" --repo "$orepo" --json comments --jq \
          '[.comments[] | select(.body | split("\n")[0] | test("^\\*\\*\\[infra-(planner|operator)\\] BLOCKED"))] | last | .url' 2>/dev/null)
        if [ -n "$orepo" ] && [ -n "$burl" ] && infra_staging_only "$orepo" "$issue" "$burl"; then echo ""; return; fi
      fi
    fi
    # BLOCKED gets a grace period — false BLOCKEDs from subagent races resolve within minutes
    if [ -n "$key" ] && [ -f "$PIPE/$key.start" ]; then
      local age=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/$key.start")") ))
      if [ "$age" -lt "$GRACE_PERIOD_SECS" ]; then
        slog "[grace] #$issue — BLOCKED marker seen but run is ${age}s old (<${GRACE_PERIOD_SECS}s), waiting"
        echo grace; return
      fi
    fi
    echo gate; return
  fi
  echo ""
}

# infra_staging_only <owner/repo> <issue> <blocked-comment-url> → 0 when a staging-only infra BLOCKED may be resumed by a
# delegated decision, 1 otherwise (claude-agents#89). All must hold: the BLOCKED is an infra-planner/operator one (not
# "Held: blocked by", not JP-only: prod/spend/secret/external comms); the issue body has a line exactly
# `Scope: staging-only`; the latest PLAN READY has no prod target step; a later `[project-manager] DECISION`/`JP CONFIRMED`
# has line 2 `Resolves: <that url>`.
infra_staging_only() {
  local owner_repo=$1 issue=$2 url=$3 json
  json=$(gh issue view "$issue" --repo "$owner_repo" --json body,comments 2>/dev/null) || return 1
  printf '%s' "$json" | jq -e --arg url "$url" '
    def l1: (.body | split("\n")[0] | rtrimstr("\r"));
    def l2: (.body | split("\n")[1] // "" | rtrimstr("\r"));
    ([.body | split("\n")[] | rtrimstr("\r") | select(. == "Scope: staging-only")] | length > 0) as $scoped
    | (.comments | map(select(.url == $url)) | first) as $b
    | if ($scoped | not) or $b == null then false else
      ($b | l1 | test("^\\*\\*\\[infra-(planner|operator)\\] BLOCKED")) as $kind
      | ($b.body | test("held: blocked by|\\bprod(uction)?\\b|\\bspend|\\bsecret|who gets access|external communication"; "i") | not) as $safe
      | ([.comments[] | select(l1 | test("\\[infra-planner\\] PLAN READY"))] | last) as $plan
      | (($plan == null) or ($plan.body | test("(target|environment|env)\\s*:\\s*prod|prod step"; "i") | not)) as $planok
      | ([.comments[] | select((l1 == "**[project-manager] DECISION**" or l1 == "**[project-manager] JP CONFIRMED**")
            and l2 == ("Resolves: " + $url) and .createdAt > $b.createdAt)] | length > 0) as $dec
      | $kind and $safe and $planok and $dec end' >/dev/null 2>&1
}

clear_in_progress() {  # <repo dir> <issue> <why> <run key> — idempotent; one gh call per issue, remembered in a marker file
  local repo=$1 issue=$2 why=$3 key=$4
  [ -f "$PIPE/$key.label-cleared" ] && return 0
  if (cd "$repo" 2>/dev/null && gh issue edit "$issue" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1); then
    touch "$PIPE/$key.label-cleared"
    slog "[label] #$issue — removed $LABEL_IN_PROGRESS ($why)"
  fi
}

do_launch() {  # <repo dir> <issue> <extra> <restart_n> <reason> <queue_wait_s> — the run key is derived from owner/repo
  local repo=$1 issue=$2 extra=$3 restart_n=${4:-0} reason=${5:-manual} queue_wait_s=${6:-}
  local owner_repo prompt title preamble="" key

  owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || owner_repo=""
  if [ -z "$owner_repo" ]; then   # no owner/repo -> no run key; leave the queue entry for the next tick (#213)
    slog "[launch] #$issue — cannot resolve owner/repo for $repo, not launching"
    pipeline_error launch "$issue" "" "launch of #$issue refused: gh repo view failed in $repo"
    return 1
  fi
  key=$(run_key "$owner_repo" "$issue")

  # Ticket title for the status board (#29): orchestrate.sh normally wrote it at launch and restarts reuse that
  # file; fetch only when it is missing. A failed or empty fetch leaves no file and never blocks the launch.
  if [ ! -f "$PIPE/$key.title" ]; then
    write_title_marker "$repo" "$issue" 0 "$key"   # one gh issue view --json title,comments (title + marker)
  fi

  if [ "$restart_n" -gt 0 ]; then
    preamble="AUTO-RESTART #$restart_n: a previous orchestrator process exited without reaching a terminal state. Verify branch/PR/comment state with gh before dispatching anything. Never redo a completed stage. "
  fi

  # Same launch shape as orchestrate.sh: the headless session IS the orchestrator (--agent), no Agent() call.
  prompt="Drive $owner_repo#$issue through the pipeline. Repo: $repo. Read the latest marker on the issue and continue from there. ${preamble}${extra}"

  printf '\n===== [%s] LAUNCH issue=%s reason=%s restart=%s =====\n' "$(date -u +%FT%TZ)" "$issue" "$reason" "$restart_n" >> "$PIPE/$key.log"
  rm -f "$PIPE/$key.exit"   # a killed run never writes it; a stale value would be reported as this run's (#38)
  cd "$repo"
  CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 nohup $SETSID bash -c '
    echo 300 > /proc/self/oom_score_adj 2>/dev/null
    claude --dangerously-skip-permissions --agent orchestrator -p "$1"
    echo $? > "$2"
  ' _ "$prompt" "$PIPE/$key.exit" >> "$PIPE/$key.log" 2>&1 9>&- &

  echo $! > "$PIPE/$key.pid"
  echo "$repo" > "$PIPE/$key.repo"
  [ -f "$PIPE/$key.start" ] || date -u +%FT%TZ > "$PIPE/$key.start"
  date -u +%FT%TZ > "$PIPE/$key.launched-at"
  rm -f "$PIPE/$key.label-cleared"
  local ev_reason=manual
  case "$reason" in auto-restart) ev_reason=auto-restart ;; queued) ev_reason=queue ;; esac
  log_run_launch "$owner_repo" "$issue" "$ev_reason" "$restart_n" "$queue_wait_s"

  slog "[launch] #$issue pid=$! reason=$reason restart=$restart_n mem=$(mem_available_mb)MB running=$(count_running)/$MAX_CONCURRENT"
}

file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# log_run_exit <repo dir> <issue> <run key> — the one writer of run_exit (design #138): classify the exit of a launched run
# (stopped > rate_limited > killed > error > normal), append the row, write .exit-class ("<class> <limit_kind|->"),
# touch .exit-logged. Never fails the tick.
log_run_exit() {
  local repo=$1 issue=$2 key=$3 rid ex="" cls lk="" last_line seg exf lf
  local launched dur now owner_repo
  exf="$PIPE/$key.exit"; lf="$PIPE/$key.log"
  rid=$(cat "$PIPE/$key.run-id" 2>/dev/null) || return 0
  [ -f "$exf" ] && ex=$(tr -dc '0-9' < "$exf")
  last_line=""; seg=$(mktemp "${TMPDIR:-/tmp}/run-exit.XXXXXX" 2>/dev/null) || seg=""
  if [ -n "$seg" ] && [ -f "$lf" ]; then
    awk '/^===== .* LAUNCH .* =====$/ {buf=""; next} {buf = buf $0 "\n"} END {printf "%s", buf}' "$lf" 2>/dev/null \
      | awk 'NF {l=$0} END {print l}' > "$seg" 2>/dev/null
    last_line=$(cat "$seg" 2>/dev/null)
  fi
  if [ -f "$PIPE/$key.stopped" ]; then cls=stopped
  elif [ -n "$seg" ] && lk=$(limit_kind_of "$seg") && [ -n "$lk" ]; then cls=rate_limited
  elif [ ! -f "$exf" ]; then cls=killed
  elif [ "${ex:-0}" != 0 ]; then cls=error
  else cls=normal; fi
  [ "$cls" = rate_limited ] || lk=""
  [ -n "$seg" ] && rm -f "$seg"
  now=$(date +%s)
  launched=$(to_epoch "$(cat "$PIPE/$key.launched-at" 2>/dev/null)")
  if [ "$launched" -gt 0 ] 2>/dev/null; then
    if [ -f "$exf" ]; then dur=$(( $(file_mtime "$exf") - launched )); else dur=$((now - launched)); fi
    [ "$dur" -ge 0 ] 2>/dev/null || dur=0
  else dur=null; fi
  owner_repo=$(cd "$repo" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null </dev/null) || owner_repo=""
  [ -n "$owner_repo" ] || owner_repo=unknown
  pipeline_event run_exit --arg run_id "$rid" --arg repo "$owner_repo" --argjson issue "$issue" \
    --argjson exit_code "${ex:-null}" --arg class "$cls" \
    --argjson limit_kind "$([ -n "$lk" ] && jq -nc --arg v "$lk" '$v' || echo null)" \
    --argjson dur_s "$dur" --arg last_line "${last_line:0:200}"
  printf '%s %s\n' "$cls" "${lk:--}" > "$PIPE/$key.exit-class" 2>/dev/null || true
  touch "$PIPE/$key.exit-logged" 2>/dev/null || true
  return 0
}

escalate() {  # <repo dir> <issue> <restarts file> <run key>
  local repo=$1 issue=$2 restarts_file=$3 key=$4
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

  touch "$PIPE/$key.held"
  rm -f "$QUEUE/$key.json"
  printf '%s Pipeline #%s held — needs manual relaunch after investigation (%s)\n' "$(date -u +%FT%TZ)" "$issue" "$owner_repo" > "$PIPE/$key.alert"
  slog "[escalate] #$issue — too many restarts without progress (queue entry purged)"
  report_status_async "escalate"   # event push: run held (design #10 §4.4)
  notify_engineering "$issue" ":rotating_light:" "Stalled — restarted multiple times without progress. Needs investigation." "$owner_repo"
}

# --- Main tick ---

launched=0

# 1. Check each recorded orchestrator
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  key=$(basename "$f" .pid); issue=${key##*-}   # run_key: the issue is the text after the last '-' (#213)
  pid=$(cat "$f")
  repo=$(cat "$PIPE/$key.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue

  # Skip if alive
  kill -0 "$pid" 2>/dev/null && continue

  # First tick that sees a launched run gone: one run_exit row (runs without a run-id predate #138 and log nothing)
  if [ -f "$PIPE/$key.run-id" ] && [ ! -f "$PIPE/$key.exit-logged" ]; then
    log_run_exit "$repo" "$issue" "$key"
  fi

  # Skip if tombstoned
  [ -f "$PIPE/$key.stopped" ] && continue
  [ -f "$PIPE/$key.held" ] && continue
  [ -f "$PIPE/$key.done" ] && continue

  # Check if terminal
  if issue_is_closed "$repo" "$issue"; then
    touch "$PIPE/$key.done"
    slog "[done] #$issue — issue closed"
    continue
  fi

  marker=$(latest_marker "$repo" "$issue")
  decision=""
  case "$marker" in *$'\n'*) decision=${marker#*$'\n'}; marker=${marker%%$'\n'*} ;; esac   # line 2 = [project-manager] marker after the gate marker
  case "$(terminal_kind "$marker" "$issue" "$decision" "$repo" "$key")" in
    done)
      touch "$PIPE/$key.done"
      slog "[done] #$issue — terminal marker: $marker"
      done_text="Deployed"; case "$marker" in *"] SPLIT"*) done_text="Split into sub-issues" ;; esac
      case "$marker" in *"] REJECTED"*) done_text="Rejected" ;; esac
      notify_engineering "$issue" ":white_check_mark:" "$done_text" "$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")"
      continue ;;
    gate)
      # Human gate (mockups, infra go, BLOCKED with no delegated decision after it): park it; JP relaunches (or re-adds
      # agent-go) after acting. $marker is the gate marker, never a [project-manager] one. A run that is already .held is
      # skipped above and stays held — held runs are not polled; the project-manager relaunches with orchestrate.sh,
      # which clears .held (claude-agents#59).
      touch "$PIPE/$key.held"
      rm -f "$QUEUE/$key.json"
      printf '%s Pipeline #%s waiting on JP — %s; relaunch (or re-add %s) after acting\n' "$(date -u +%FT%TZ)" "$issue" "$marker" "$LABEL_GO" > "$PIPE/$key.alert"
      slog "[held] #$issue — waiting on JP: $marker"
      report_status_async "held"   # event push: run held/gate (design #10 §4.4)
      gate_reason=$(echo "$marker" | sed 's/\*\*\[[^]]*\]\*\* *//; s/^ *//; s/ *$//')
      [ -z "$gate_reason" ] && gate_reason="$marker"
      notify_engineering "$issue" ":hand:" "Waiting on you — $gate_reason" "$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")"
      continue ;;
    grace) continue ;;
  esac

  # How this run ended (written by log_run_exit; absent for runs launched before #138)
  exit_class=""; exit_lk=""
  [ -f "$PIPE/$key.exit-class" ] && read -r exit_class exit_lk < "$PIPE/$key.exit-class"
  [ "$exit_lk" = "-" ] && exit_lk=""

  restarts_file="$PIPE/$key.restarts"
  exit_code=$(cat "$PIPE/$key.exit" 2>/dev/null || echo "?")

  if [ "$exit_class" = rate_limited ] && [ "$exit_lk" = monthly_spend ]; then
    # Restarting cannot fix it and clearing it means spending money: park like a human gate. Counters untouched.
    run_owner_repo=$(cd "$repo" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "unknown")
    python3 - "$restarts_file" "$(date -u +%FT%TZ)" "$exit_code" "$marker" "$exit_class" "$exit_lk" <<'PY' 2>/dev/null
import json, sys
path, ts, ex, marker, cls, lk = sys.argv[1:7]
try: d = json.load(open(path))
except Exception: d = {'count': 0, 'total': 0, 'last_marker': '', 'history': []}
d.setdefault('history', []).append({'ts': ts, 'exit': ex, 'marker': marker, 'transient': False, 'run_secs': 0, 'class': cls, 'limit_kind': lk or None})
json.dump(d, open(path, 'w'))
PY
    touch "$PIPE/$key.held"
    rm -f "$QUEUE/$key.json"
    printf '%s Pipeline #%s waiting on JP — monthly spend limit reached; relaunch after credits or a model switch\n' "$(date -u +%FT%TZ)" "$issue" > "$PIPE/$key.alert"
    slog "[held] #$issue — monthly spend limit: needs JP"
    report_status_async "held"
    notify_engineering "$issue" ":hand:" "Waiting on you — monthly spend limit reached" "$run_owner_repo"
    continue
  fi

  # Already queued — nothing ended this tick: don't count it, don't overwrite its not_before
  if [ -f "$QUEUE/$key.json" ]; then
    slog "[queue-wait] #$issue — already queued, skipping re-enqueue"
    continue
  fi

  if [ "$exit_class" = rate_limited ]; then
    # Weekly / unrecognised limit: wait, don't count (never trips the "stalled" escalation)
    python3 - "$restarts_file" "$(date -u +%FT%TZ)" "$exit_code" "$marker" "$exit_class" "$exit_lk" <<'PY' 2>/dev/null
import json, sys
path, ts, ex, marker, cls, lk = sys.argv[1:7]
try: d = json.load(open(path))
except Exception: d = {'count': 0, 'total': 0, 'last_marker': '', 'history': []}
d.setdefault('history', []).append({'ts': ts, 'exit': ex, 'marker': marker, 'transient': False, 'run_secs': 0, 'class': cls, 'limit_kind': lk or None})
json.dump(d, open(path, 'w'))
PY
    extra=$(cat "$PIPE/$key.extra" 2>/dev/null || echo "")
    not_before=$(( $(date +%s) + RATE_LIMIT_BACKOFF_SECS ))
    python3 - "$QUEUE/$key.json" "$issue" "$repo" "$extra" "$(date -u +%FT%TZ)" "$not_before" <<'PY' 2>/dev/null
import json, sys
path, issue, repo, extra, qa, nb = sys.argv[1:7]
json.dump({'issue': issue, 'repo': repo, 'extra': extra, 'reason': 'auto-restart', 'queued_at': qa, 'not_before': int(nb)}, open(path, 'w'))
PY
    slog "[rate-limited] #$issue limit=$exit_lk backoff=${RATE_LIMIT_BACKOFF_SECS}s"
    report_status_async "queue-restart"
    continue
  fi

  # Non-terminal exit — potential restart
  [ "$launched" -ge 1 ] && continue  # one launch per tick
  extra=$(cat "$PIPE/$key.extra" 2>/dev/null || echo "")

  # Detect transient exit: use per-launch timestamp (.launched-at), not the original .start
  # .start is preserved across restarts (used by BLOCKED grace window); .launched-at tracks this launch only
  run_duration=0
  if [ -f "$PIPE/$key.launched-at" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/$key.launched-at")") ))
  elif [ -f "$PIPE/$key.start" ]; then
    run_duration=$(( $(date +%s) - $(to_epoch "$(cat "$PIPE/$key.start")") ))
  fi
  transient=false
  [ "$run_duration" -lt "$MIN_RUN_SECS" ] && transient=true

  # Deliberate stop: the run that just ended logged a validate fail of a deliberate-stop stage (start-gate, closed PR, refused delegated decision, loop cap).
  # A restart cannot heal it — hold instead of looping to MAX_TOTAL. Other stages (concurrency-gate, ...) still restart.
  # "This run" = ts >= .launched-at. One list of stage values: structural (claude-agents#92), delegated-decision, loop-cap (#88).
  since=$(cat "$PIPE/$key.launched-at" 2>/dev/null || cat "$PIPE/$key.start" 2>/dev/null)   # this launch's start (no GNU date -d: BSD date lacks it)
  found_stage=""
  if [ -n "$since" ] && [ -f "$HOME/.claude/pipeline/runs.jsonl" ]; then
    found_stage=$(python3 - "$HOME/.claude/pipeline/runs.jsonl" "$issue" "$since" <<'PY' 2>/dev/null
import json, sys
path, issue, since = sys.argv[1], int(sys.argv[2]), sys.argv[3]
for line in open(path):
    try: r = json.loads(line)
    except ValueError: continue
    if (r.get("issue") == issue and r.get("event") == "validate" and r.get("result") == "fail"
            and r.get("stage") in ("structural", "delegated-decision", "loop-cap") and str(r.get("ts", "")) >= since):
        print(r.get("stage"))
        break
PY
)
  fi
  if [ -n "$found_stage" ]; then
    touch "$PIPE/$key.held"
    case "$found_stage" in
      loop-cap) hold_reason="loop-cap stop" ;;
      delegated-decision) hold_reason="refused delegated decision" ;;
      *) hold_reason="structural stop (start-gate / closed PR)" ;;
    esac
    slog "[held] #$issue — $hold_reason, needs a relaunch after it is resolved"
    report_status_async "held"
    continue
  fi

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
d['history'].append({'ts':'$(date -u +%FT%TZ)','exit':'$exit_code','marker':'''$marker''','transient':$($transient && echo True || echo False),'run_secs':$run_duration,'class':$([ -n "$exit_class" ] && echo "'$exit_class'" || echo None),'limit_kind':$([ -n "$exit_lk" ] && echo "'$exit_lk'" || echo None)})
d['count']=$count; d['total']=$total; d['last_marker']='''$marker'''
json.dump(d, open('$restarts_file','w'))
" 2>/dev/null

  if $should_escalate; then
    escalate "$repo" "$issue" "$restarts_file" "$key"
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
json.dump({'issue':'$issue','repo':'$repo','extra':'''$extra''','reason':'auto-restart','queued_at':'$(date -u +%FT%TZ)','not_before':$not_before}, open('$QUEUE/$key.json','w'))
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
  best_key=""   # run key of the oldest eligible entry (its queue file name)
  best_order=""

  for qf in "$QUEUE"/orch-*.json; do
    [ -e "$qf" ] || break
    q_key=$(basename "$qf" .json)
    not_before=$(python3 -c "import json; print(json.load(open('$qf')).get('not_before',0))" 2>/dev/null || echo 0)
    [ "$now_epoch" -lt "$not_before" ] && continue

    q_issue=$(python3 -c "import json; print(json.load(open('$qf'))['issue'])" 2>/dev/null)
    # Skip if tombstoned (stopped, held, or done)
    if [ -f "$PIPE/$q_key.stopped" ] || [ -f "$PIPE/$q_key.held" ] || [ -f "$PIPE/$q_key.done" ]; then
      rm -f "$qf"
      slog "[drain-skip] #$q_issue — tombstoned, purging queue entry"
      continue
    fi
    # Skip if already running
    if [ -f "$PIPE/$q_key.pid" ] && kill -0 "$(cat "$PIPE/$q_key.pid")" 2>/dev/null; then
      rm -f "$qf"
      continue
    fi

    # Order key: queued_at epoch (fallback: file mtime when missing/unparseable), then issue number
    q_order=$(python3 -c "
import json, os, datetime
f='$qf'
try:
    t=datetime.datetime.strptime(json.load(open(f))['queued_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
except Exception:
    t=os.path.getmtime(f)
print('%d %d' % (int(t), int('$q_issue')))
" 2>/dev/null)
    [ -z "$q_order" ] && q_order="$(stat -c %Y "$qf" 2>/dev/null || stat -f %m "$qf") ${q_issue//[!0-9]/}"
    if [ -z "$best_qf" ] || python3 -c "import sys; a=tuple(map(int,'$q_order'.split())); b=tuple(map(int,'$best_order'.split())); sys.exit(0 if a<b else 1)"; then
      best_qf="$qf"
      best_issue="$q_issue"
      best_key="$q_key"
      best_order="$q_order"
    fi
  done

  if [ -n "$best_qf" ]; then
    q_repo=$(python3 -c "import json; print(json.load(open('$best_qf'))['repo'])" 2>/dev/null)
    q_extra=$(python3 -c "import json; print(json.load(open('$best_qf')).get('extra',''))" 2>/dev/null)
    q_reason=$(python3 -c "import json; print(json.load(open('$best_qf')).get('reason','queued'))" 2>/dev/null)
    restart_n=0
    if [ "$q_reason" = "auto-restart" ] && [ -f "$PIPE/$best_key.restarts" ]; then
      restart_n=$(python3 -c "import json; print(json.load(open('$PIPE/$best_key.restarts')).get('count',0))" 2>/dev/null || echo 0)
    fi

    q_wait=$(python3 -c "
import json, datetime, time
try:
    t = datetime.datetime.strptime(json.load(open('$best_qf'))['queued_at'], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()
    print(max(0, int(time.time() - t)))
except Exception:
    pass
" 2>/dev/null)
    if do_launch "$q_repo" "$best_issue" "$q_extra" "$restart_n" "$q_reason" "$q_wait"; then
      rm -f "$best_qf"
      launched=1
    else   # owner/repo unresolved: keep the entry, retry after the first restart backoff step instead of re-posting every tick
      python3 - "$best_qf" "$(( $(date +%s) + ${BACKOFF[0]} ))" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1])); d['not_before'] = int(sys.argv[2]); json.dump(d, open(sys.argv[1], 'w'))
PY
    fi
  fi
fi

# 3. Label lifecycle — agent-in-progress means "an orchestrator owns this somewhere"; drop it once this machine
#    finished (done), parked (held: gate or escalation), stopped, or dead with no pending relaunch.
for f in "$PIPE"/orch-*.pid; do
  [ -e "$f" ] || break
  key=$(basename "$f" .pid); issue=${key##*-}
  repo=$(cat "$PIPE/$key.repo" 2>/dev/null || echo "")
  [ -z "$repo" ] && continue
  kill -0 "$(cat "$f")" 2>/dev/null && continue
  if   [ -f "$PIPE/$key.done" ];    then clear_in_progress "$repo" "$issue" done "$key"
  elif [ -f "$PIPE/$key.held" ];    then clear_in_progress "$repo" "$issue" held "$key"
  elif [ -f "$PIPE/$key.stopped" ]; then clear_in_progress "$repo" "$issue" stopped "$key"
  elif [ ! -f "$QUEUE/$key.json" ]; then
    clear_in_progress "$repo" "$issue" "dead-no-queue" "$key"
    slog "[label] #$issue — process dead, no queue entry, cleared orphaned label"
  fi
done

# 3b. Intake — triage raw staff feedback (#114): one `user-feedback-intake` issue per tick from DISPATCH_REPOS, claimed like
#     step 5, label swapped to agent-in-progress, `claude --agent intake -p` launched detached. State is separate from the
#     orchestrator's (PIPE/intake-<owner_repo>-<n>.*) but counts against MAX_CONCURRENT. A run that exits with no [intake]
#     marker gets one recovery launch; a second failure posts a NOTE, re-adds the label once and parks it locally (.gaveup).
intake_key() { printf 'intake-%s-%s' "${1//\//_}" "$2"; }
intake_launch() {  # <owner/repo> <local path> <issue> <prompt>
  local k; k=$(intake_key "$1" "$3")
  echo 0 > "$PIPE/$3-intake-before.txt"; rm -f "$PIPE/$k.exit" "$PIPE/$k.exit-seen"
  # #176: remember a source:sentry issue at launch, so the agent removing the label cannot turn the agent-go strip into a no-op
  case " $(gh issue view "$3" --repo "$1" --json labels --jq '[.labels[].name] | join(" ")' 2>/dev/null) " in
    *" source:sentry "*) touch "$PIPE/$k.sentry" ;; esac
  ( cd "$PIPE" && PIPELINE_ISSUE="$3" PIPELINE_AGENT=intake PIPELINE_REPO="$1" PIPE="$PIPE" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
    nohup $SETSID bash -c 'claude --dangerously-skip-permissions --agent intake -p "$1"; echo $? > "$2"' _ "$4" "$PIPE/$k.exit" \
    >> "$PIPE/$k.log" 2>&1 9>&- & echo $! > "$PIPE/$k.pid" )
  echo "$2" > "$PIPE/$k.path"; echo "$1 $3" > "$PIPE/$k.id"
  echo $(( $(cat "$PIPE/$k.attempts" 2>/dev/null || echo 0) + 1 )) > "$PIPE/$k.attempts"
  slog "[intake] $1#$3 launched (attempt $(cat "$PIPE/$k.attempts"))"
}
# code-enforced gate (#176): the intake agent reads attacker-influenced text, so a source:sentry issue never keeps agent-go
# unless SENTRY_AUTO_GO=1, whatever the agent did. Returns 1 when the label read fails (caller retries next tick), else 0.
sentry_strip_go() {  # <owner/repo> <issue>
  [ "${SENTRY_AUTO_GO:-0}" = 1 ] && return 0
  local lbls k; k=$(intake_key "$1" "$2")
  lbls=$(gh issue view "$2" --repo "$1" --json labels --jq '[.labels[].name] | join(" ")' 2>/dev/null) || {
    slog "[intake] $1#$2 label read failed — will retry the source:sentry $LABEL_GO strip next tick"; return 1; }
  # sentry = recorded at launch (survives the agent removing the label) OR labelled now
  if [ -e "$PIPE/$k.sentry" ]; then lbls="$lbls source:sentry"; fi
  case " $lbls " in *" source:sentry "*)
    case " $lbls " in *" $LABEL_GO "*)
      if gh issue edit "$2" --repo "$1" --remove-label "$LABEL_GO" >/dev/null 2>&1; then
        slog "[intake] $1#$2 source:sentry carried $LABEL_GO with SENTRY_AUTO_GO=0 — removed"
      else
        slog "[intake] $1#$2 failed to remove $LABEL_GO from source:sentry issue — will retry next tick"; return 1
      fi ;;
    esac ;;
  esac
  return 0
}
INTAKE_RE=$(marker_re intake | jq -Rs .)
for idf in "$PIPE"/intake-*.id; do   # runs that have exited: healthy -> clear state; no marker -> recover once, then give up
  [ -e "$idf" ] || break
  k=$(basename "$idf" .id); read -r i_repo i_num < "$idf"; i_path=$(cat "$PIPE/$k.path")
  if kill -0 "$(cat "$PIPE/$k.pid" 2>/dev/null)" 2>/dev/null; then
    sentry_strip_go "$i_repo" "$i_num" || launched=1   # live run: strip an injected agent-go before step 5 can dispatch it (also strips a hand-added one until intake finishes); a failed strip holds dispatch this tick
    continue
  fi
  # done = a terminal marker (a NEEDS INFO-only run that died before labelling is not done) or the issue already carries user-feedback
  have=$(gh issue view "$i_num" --repo "$i_repo" --json comments,labels \
    --jq "([.comments[].body | split(\"\\n\")[0] | select(test(\"^\\\\*\\\\*\\\\[intake\\\\] (TRIAGED BUG|TRIAGED IDEA|DUPLICATE|NOISE|BLOCKED)\"))] | length) + ([(.labels // [])[].name | select(. == \"user-feedback\")] | length)" 2>/dev/null) || continue
  if [ "${have:-0}" -gt 0 ]; then
    sentry_strip_go "$i_repo" "$i_num" || { launched=1; continue; }   # keep state so the next tick retries the strip; hold dispatch this tick
    gh issue edit "$i_num" --repo "$i_repo" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1
    rm -f "$PIPE/$k".{id,pid,path,exit,exit-seen,attempts,sentry}; slog "[intake] $i_repo#$i_num done"
  elif [ ! -e "$PIPE/$k.exit-seen" ]; then
    touch "$PIPE/$k.exit-seen"   # one grace tick: a slow marker or a lagging gh read must not trigger a recovery run
  elif [ "$(cat "$PIPE/$k.attempts" 2>/dev/null || echo 1)" -lt 2 ]; then
    [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ] || continue
    intake_launch "$i_repo" "$i_path" "$i_num" "Triage $i_repo#$i_num as the intake agent. A previous run exited without posting an [intake] handoff marker: check the issue state with gh, finish the triage if it is incomplete, and post the handoff marker."
    launched=1
  else
    sentry_strip_go "$i_repo" "$i_num" || { launched=1; continue; }   # keep state (no .gaveup) so the next tick retries the strip; hold dispatch this tick
    gh issue comment "$i_num" --repo "$i_repo" --body "**[supervisor] NOTE** intake ran twice without a handoff marker; the issue is back in the intake queue for manual attention." >/dev/null 2>&1
    gh issue edit "$i_num" --repo "$i_repo" --remove-label "$LABEL_IN_PROGRESS" --add-label user-feedback-intake >/dev/null 2>&1
    rm -f "$PIPE/$k".{id,pid,path,exit,exit-seen,sentry}; touch "$PIPE/$k.gaveup"; slog "[intake] $i_repo#$i_num gave up after 2 runs without a marker"
  fi
done
if [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ] && power_ok; then
  cutoff=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=$CLAIM_WINDOW_SECS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  for entry in "${DISPATCH_REPOS[@]}"; do
    [ "$launched" -ge 1 ] && break
    owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
    case "$owner_repo" in */Business-Intelligence) continue ;; esac
    [ -d "$local_path/.git" ] || continue
    for num in $(gh issue list --repo "$owner_repo" --state open --label user-feedback-intake --limit 50 --json number,labels \
        --jq ".[] | select([.labels[].name] | index(\"$LABEL_IN_PROGRESS\") | not) | .number" 2>/dev/null); do
      case "$num" in ''|*[!0-9]*) continue ;; esac
      k=$(intake_key "$owner_repo" "$num"); [ -e "$PIPE/$k.id" ] || [ -e "$PIPE/$k.gaveup" ] && continue
      ts=$(date -u +%FT%TZ)
      gh issue comment "$num" --repo "$owner_repo" --body "**[supervisor] NOTE** claim: $HOST $ts" >/dev/null 2>&1 || continue
      sleep "$CLAIM_SETTLE_SECS"
      winner=$(gh issue view "$num" --repo "$owner_repo" --json comments \
        --jq "[.comments[] | select(.body | startswith(\"**[supervisor] NOTE** claim: \")) | select(.createdAt > \"$cutoff\")] | sort_by(.createdAt) | first | .body" 2>/dev/null | awk '{print $4}')
      [ "$winner" = "$HOST" ] || { slog "[intake] $owner_repo#$num — lost claim to ${winner:-?}"; continue; }
      gh issue edit "$num" --repo "$owner_repo" --add-label "$LABEL_IN_PROGRESS" --remove-label user-feedback-intake >/dev/null 2>&1
      rm -f "$PIPE/$k.attempts" "$PIPE/$k.sentry"
      intake_launch "$owner_repo" "$local_path" "$num" "Triage $owner_repo#$num as the intake agent."
      launched=1; break
    done
  done
fi

# 3c. Spec — PM-only run (#115) for one `user-feedback-needs-spec` idea: claim, swap in agent-in-progress, launch `claude --agent product-manager -p`.
#     Never adds agent-go and never starts an orchestrator. When the PM exits, drop agent-in-progress + needs-spec and add agent-proposed (JP's digest).
#     Any PM routing marker except REJECTED blocks a launch, as do two REJECTED needs-spec (a PM REJECTED needs-spec is how a fix reaches here). State: PIPE/spec-<owner_repo>-<n>.*
spec_key() { printf 'spec-%s-%s' "${1//\//_}" "$2"; }
spec_pm_markers() {  # <owner/repo> <issue> → PM routing markers other than REJECTED, +1 once two REJECTED needs-spec are on the issue (re-reject loop stop)
  gh issue view "$2" --repo "$1" --json comments 2>/dev/null | jq --arg re "$(marker_re product-manager)" '[.comments[].body | split("\n")] as $c
    | ([$c[] | select(.[0] | test($re) and (test("\\] REJECTED") | not))] | length)
    + (if ([$c[] | select((.[0] | test("^\\*\\*\\[(product-manager|fullstack-developer)\\] REJECTED")) and ((.[1] // "") | test("^Reason: needs-spec")))] | length) >= 2 then 1 else 0 end)' 2>/dev/null
}
for idf in "$PIPE"/spec-*.id; do   # exited PM runs: marker posted -> hand the spec to JP; none -> one retry, then park
  [ -e "$idf" ] || break
  k=$(basename "$idf" .id); read -r s_repo s_num < "$idf"
  kill -0 "$(cat "$PIPE/$k.pid" 2>/dev/null)" 2>/dev/null && continue
  m=$(spec_pm_markers "$s_repo" "$s_num"); case "$m" in ''|*[!0-9]*) continue ;; esac   # failed gh/jq lookup: act on nothing, retry next tick
  if [ "$m" != 0 ]; then
    gh issue edit "$s_num" --repo "$s_repo" --remove-label "$LABEL_IN_PROGRESS" --remove-label user-feedback-needs-spec --add-label "$LABEL_PROPOSED" >/dev/null 2>&1
    rm -f "$PIPE/$k".{id,pid,path,attempts}; slog "[spec] $s_repo#$s_num spec written, moved to $LABEL_PROPOSED"
  else
    gh issue edit "$s_num" --repo "$s_repo" --remove-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1; rm -f "$PIPE/$k".{id,pid,path}
    [ "$(cat "$PIPE/$k.attempts" 2>/dev/null || echo 1)" -ge 2 ] && { touch "$PIPE/$k.gaveup"; slog "[spec] $s_repo#$s_num gave up: no PM marker after 2 runs"; }
  fi
done
if [ "$launched" -eq 0 ] && [ "$HAS_CAP" -eq 1 ] && [ "${#DISPATCH_REPOS[@]}" -gt 0 ] && power_ok; then
  cutoff=$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=$CLAIM_WINDOW_SECS)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  for entry in "${DISPATCH_REPOS[@]}"; do
    [ "$launched" -ge 1 ] && break
    owner_repo="${entry%%:*}"; local_path="${entry#*:}"; local_path="${local_path/#\~/$HOME}"
    case "$owner_repo" in */Business-Intelligence) continue ;; esac
    [ -d "$local_path/.git" ] || continue
    for num in $(gh issue list --repo "$owner_repo" --state open --label user-feedback-needs-spec --limit 50 --json number,labels \
        --jq ".[] | select([.labels[].name] | (index(\"$LABEL_IN_PROGRESS\") or index(\"$LABEL_GO\") or index(\"source:sentry\")) | not) | .number" 2>/dev/null); do
      case "$num" in ''|*[!0-9]*) continue ;; esac
      k=$(spec_key "$owner_repo" "$num"); [ -e "$PIPE/$k.id" ] || [ -e "$PIPE/$k.gaveup" ] && continue
      [ "$(spec_pm_markers "$owner_repo" "$num")" = 0 ] || continue
      gh issue comment "$num" --repo "$owner_repo" --body "**[supervisor] NOTE** claim: $HOST $(date -u +%FT%TZ)" >/dev/null 2>&1 || continue
      sleep "$CLAIM_SETTLE_SECS"
      winner=$(gh issue view "$num" --repo "$owner_repo" --json comments \
        --jq "[.comments[] | select(.body | startswith(\"**[supervisor] NOTE** claim: \")) | select(.createdAt > \"$cutoff\")] | sort_by(.createdAt) | first | .body" 2>/dev/null | awk '{print $4}')
      [ "$winner" = "$HOST" ] || { slog "[spec] $owner_repo#$num — lost claim to ${winner:-?}"; continue; }
      gh issue edit "$num" --repo "$owner_repo" --add-label "$LABEL_IN_PROGRESS" >/dev/null 2>&1
      ( cd "$PIPE" && PIPELINE_ISSUE="$num" PIPELINE_AGENT=product-manager PIPELINE_REPO="$owner_repo" PIPE="$PIPE" CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 \
        nohup $SETSID bash -c 'claude --dangerously-skip-permissions --agent product-manager -p "$1"; echo $? > "$2"' _ \
        "Write the spec for $owner_repo#$num as the product-manager (spec-only run for a user-feedback idea): do not add agent-go; do not file dependency follow-ups on this issue; post your READY marker." "$PIPE/$k.exit" \
        >> "$PIPE/$k.log" 2>&1 9>&- & echo $! > "$PIPE/$k.pid" )
      echo "$owner_repo $num" > "$PIPE/$k.id"; echo $(( $(cat "$PIPE/$k.attempts" 2>/dev/null || echo 0) + 1 )) > "$PIPE/$k.attempts"
      slog "[spec] $owner_repo#$num launched (attempt $(cat "$PIPE/$k.attempts"))"; launched=1; break
    done
  done
fi

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
      k=$(run_key "$owner_repo" "$num")
      if [ -f "$PIPE/$k.pid" ] && kill -0 "$(cat "$PIPE/$k.pid" 2>/dev/null)" 2>/dev/null; then continue; fi
      [ -f "$QUEUE/$k.json" ] && continue
      [ -e "$PIPE/$(intake_key "$owner_repo" "$num").id" ] && continue   # an intake run (3b) owns it
      [ -e "$PIPE/spec-${owner_repo//\//_}-$num.id" ] && continue   # a spec run (3c) owns it
      # Check marker staleness — only clear if no movement for STALE_LABEL_SECS
      # Same call also yields the latest "claim: <host>" comment: a claim naming another machine means it owns the run.
      view=$(cd "$local_path" && gh issue view "$num" --json comments,updatedAt \
        --jq '((.comments[-1].createdAt // .updatedAt) // ""), ([.comments[] | select(.body | startswith("**[supervisor] NOTE** claim: "))] | last | .body // "" | split(" ") | .[3] // "")' 2>/dev/null)
      last_comment_age=$(printf '%s\n' "$view" | sed -n 1p)
      claim_host=$(printf '%s\n' "$view" | sed -n 2p)
      [ -n "$claim_host" ] && [ "$claim_host" != "$HOST" ] && continue
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
        k=$(run_key "$owner_repo" "$num")
        if [ -f "$PIPE/$k.pid" ] && kill -0 "$(cat "$PIPE/$k.pid")" 2>/dev/null; then continue; fi
        [ -f "$QUEUE/$k.json" ] && continue

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
        rm -f "$PIPE/$k".{stopped,held,done,closed,marker,milestone,alert,label-cleared} "$PIPE/$k.restarts"
        out=$(LAUNCH_REASON=agent-go "$(dirname "${BASH_SOURCE[0]}")/orchestrate.sh" --force "$local_path" "$num" 2>&1 | tail -1)
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

#!/bin/bash
# Push a status-board heartbeat. See issue #10 Design + #4 §3/§4 (frozen v1 payload).
# Usage: report-status.sh [event-name]     push (or skip) a real heartbeat, always exit 0
#        report-status.sh --print          build + print the v1 payload only: no lock, no
#                                           network, no state write (used by ACs 1/2/5's tests
#                                           and safe to run by hand to inspect what would be sent)
#
# Never invoked directly by a call site — always through run-state.sh's report_status_async,
# which backgrounds it, redirects its output, and can't propagate its exit code (AC8).
RS_HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$RS_HERE/run-state.sh"   # sources config.sh itself; also gives us derive_runs()

# --- Write-budget constants (AC12) -----------------------------------------------------------
# Verified against Cloudflare's live KV limits page for this PR: Free plan "Writes to different
# keys: 1,000 writes per day" — https://developers.cloudflare.com/kv/platform/limits/ (page
# "Last updated" Apr 21 2026), checked 2026-09-17. The design's starting number (1,000/day) holds.
#
# Arithmetic (per host unless noted; #240):
#   MIN_PUSH_INTERVAL_SECS is derived below as max(10, ceil(86400 / MAX_PUSHES_PER_DAY)), so
#   pushes/day <= 86400 / MIN_PUSH_INTERVAL_SECS <= MAX_PUSHES_PER_DAY: the cap is an unreachable
#   backstop and the page can never go dark mid-day (400 -> 216 s, 450 -> 192 s, 550 -> 158 s).
#   keep-alive  86400 / KEEPALIVE_SECS(600)  = 144 writes/day (longer than the interval, so it
#                                              never adds pushes beyond the spacing bound)
#   both hosts' caps together stay <= the KV free tier's 1,000 writes/day.
#   Worst-case page lag ~ interval + one 2-minute tick (~5 min) vs the 1,500 s stale threshold.
MIN_PUSH_INTERVAL_SECS=10
KEEPALIVE_SECS=600
MAX_PUSHES_PER_DAY=400
# Host override (2026-09-22): a busy host may raise its own share in ~/.claude/pipeline/config.local.sh
# as long as both hosts together stay under the KV free tier (1,000 writes/day).
[ -f "$HOME/.claude/pipeline/config.local.sh" ] && { _mp=$(grep -E "^MAX_PUSHES_PER_DAY=[0-9]+" "$HOME/.claude/pipeline/config.local.sh" | tail -1 | sed -E "s/^MAX_PUSHES_PER_DAY=([0-9]+).*/\1/"); [ -n "$_mp" ] && MAX_PUSHES_PER_DAY=$_mp; }
# Spacing derived from the final cap (#240): a coalescing interval of 10 s alone does not bound daily volume.
_min_gap=$(( (86400 + MAX_PUSHES_PER_DAY - 1) / MAX_PUSHES_PER_DAY ))
[ "$_min_gap" -gt "$MIN_PUSH_INTERVAL_SECS" ] && MIN_PUSH_INTERVAL_SECS=$_min_gap

EVENT="${1:-event}"
CACHE="$PIPE/status-push.state"

# AC6 — unset URL or token: silent no-op, no network, no log, nothing on stdout/stderr. Does not
# gate --print (ACs 1/2/5 build/inspect the payload with no push endpoint configured at all).
if [ "$EVENT" != "--print" ]; then
  [ -n "${STATUS_PUSH_URL:-}" ] && [ -n "${STATUS_PUSH_TOKEN:-}" ] || exit 0
fi

mkdir -p "$PIPE" "$QUEUE" 2>/dev/null

# ---- repo alias (AC5): git -C <repo_path> config --get remote.origin.url (local, no network)
# -> owner/repo -> STATUS_REPO_ALIASES ("owner/repo:alias", a plain indexed array — see AC11) ->
# unmapped -> "other".
# ---- ticket title (#29): the builder reads $PIPE/orch-<issue>.title (written at launch by
# orchestrate.sh / supervisor.sh) and emits runs[].title + runs[].url. Local file only — a beat
# never makes a network call for a title; no file means neither field.
_rs_aliases_arg() {
  local e out=""
  for e in "${STATUS_REPO_ALIASES[@]:-}"; do
    [ -n "$e" ] && out="$out$e"$'\n'
  done
  printf '%s' "$out"
}

# ---- payload ----------------------------------------------------------------------------------
# The runs[] builder is a standalone file, not an inline heredoc: a heredoc attached to `python3 -`
# consumes the script's own stdin, leaving nothing for derive_runs()'s TSV to be piped through.
_rs_build_runs_json() {  # reads derive_runs()'s TSV on stdin, prints the v1 "runs" JSON array
  python3 "$RS_HERE/build-runs-json.py" "$(_rs_aliases_arg)" "$HOME/.claude/pipeline/runs.jsonl" "$PIPE"
}

_rs_build_completed_json() {  # same TSV on stdin, prints the payload's "completed" JSON array (issue #51)
  python3 "$RS_HERE/build-runs-json.py" "$(_rs_aliases_arg)" "$HOME/.claude/pipeline/runs.jsonl" "$PIPE" completed
}

_rs_build_list_json() {  # <staging|approved>: the payload's host-published GitHub lists (issue #65), local files only
  python3 "$RS_HERE/build-runs-json.py" "$(_rs_aliases_arg)" "$HOME/.claude/pipeline/runs.jsonl" "$PIPE" "$1" </dev/null
}

_rs_build_goals_json() {  # the payload's goals array (issue #197), local goal-<id>.* files only
  python3 "$RS_HERE/build-runs-json.py" "$(_rs_aliases_arg)" "$HOME/.claude/pipeline/runs.jsonl" "$PIPE" goals </dev/null
}

_rs_build_goal_stall_json() {  # the payload's goal_stall array (status-page alert banner): goalqueue.json + a bounded tail of events.jsonl, local only
  STATUS_EVENTS_FILE="${STATUS_EVENTS_FILE:-$LOGDIR/events.jsonl}" \
    python3 "$RS_HERE/build-runs-json.py" "$(_rs_aliases_arg)" "$HOME/.claude/pipeline/runs.jsonl" "$PIPE" goalstall </dev/null
}

_rs_build_scheduled_triggers_json() {  # the payload's scheduled_triggers array (#769): the release router heartbeat, local files only. `repo` is the alias; `full_repo` (owner/repo, aliased repos only) names it in the alert (#783)
  local aliases; aliases=$(_rs_aliases_arg)
  "$RS_HERE/scheduled-triggers.sh" status 2>/dev/null | jq -c --arg aliases "$aliases" '
    ($aliases | split("\n") | map(select(contains(":")) | {key: .[0:index(":")], value: .[index(":")+1:]}) | from_entries) as $a
    | map((if $a[.repo] then .full_repo = .repo else . end) | .repo = ($a[.repo] // "other"))' 2>/dev/null
}

_rs_supervisor_last_tick() {  # mtime of the supervisor's own log, else "now" (no supervisor has run yet)
  local log="$LOGDIR/supervisor.log" epoch
  if [ -e "$log" ]; then
    epoch=$(_rs_mtime "$log")
    if [ -n "$epoch" ]; then
      python3 -c "import datetime,sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$epoch" 2>/dev/null
      return
    fi
  fi
  printf '%s' "$SENT_AT"
}

_rs_build_backlog_json() {  # the payload's backlog array (backlog reorder view), local files only
  python3 "$RS_HERE/build-runs-json.py" "$(_rs_aliases_arg)" "$HOME/.claude/pipeline/runs.jsonl" "$PIPE" backlog </dev/null
}

# ---- ci_queue (issue #643): read-only — this reporter never calls GitHub for it. The host-side
# collector (infra/ci-runners/ci-queue-collect.sh, invoked below) writes $PIPE/status-ci.json on
# its own throttled cadence; this just reads that local file, local-only, same as goals/backlog.
# Absent, unreadable, not a JSON object, or older than STATUS_CI_STALE_SECS -> "" (key omitted
# entirely from the payload — never sent as null/empty, per AC7).
#
# Issue #663 AC1a: this used to default to 1200s (20 min) — well UNDER vocab.js's own
# offlineSecs (3 * staleSecs, staleSecs = round(2.5 * KEEPALIVE_SECS/60)*60 = 1500s with
# KEEPALIVE_SECS=600, so offlineSecs=4500s/75min). That meant this reporter dropped `ci_queue`
# from the beat 55 minutes before the Worker/render layer's own as_of-based staleness logic
# (render.js's renderCiQueuePanel) ever got a chance to classify it as stale/offline — the
# collector-outage case this field exists to surface showed "no CI queue data yet" instead.
# Raised to 7200s (2h), strictly greater than any reasonable offlineSecs so the render layer's
# own classification always runs first. This is a backstop against reporting a multi-day-old
# file forever, never the staleness decision itself — that still lives in render.js/vocab.js.
STATUS_CI_STALE_SECS=${STATUS_CI_STALE_SECS:-7200}   # 2h default — backstop only, see above
_rs_ci_queue_json() {
  local f="$PIPE/status-ci.json" mtime now
  [ -e "$f" ] || { printf ''; return; }
  mtime=$(_rs_mtime "$f")
  [ -n "$mtime" ] || { printf ''; return; }
  now=$(date +%s)
  [ $((now - mtime)) -le "$STATUS_CI_STALE_SECS" ] || { printf ''; return; }
  jq -ce 'select(type=="object")' "$f" 2>/dev/null || printf ''
}

# ---- cron (issue #756): the host user's scheduled jobs, name + schedule + last run/result only.
# STATUS_CRON_CMD reads the crontab (default `crontab -l`; run-tests.sh points it at `true` so a
# host's real crontab never leaks into a test payload). build-runs-json.py's `cron` mode does the
# parsing and the ~/logs/<job>/ scan; the crontab text and log content stay in that process.
# Sets CRON_JSON ("" = key omitted: no jobs, or any failure) and CRON_ERR (a fixed error class, never
# crontab text, or ""). A crontab with no entries ("no crontab for <user>") is not an error. Never
# fails the beat. Not run in a $(...) subshell on purpose: both globals must survive.
# On macOS the same python pass also lists the user's launchd jobs and Claude desktop scheduled tasks
# (STATUS_LAUNCHD_DIR / STATUS_DESKTOP_TASKS_DIR override their directories, "" turns one off; run-tests.sh
# turns both off), so a missing or unreadable crontab still runs it, with empty crontab text.
STATUS_CRON_CMD="${STATUS_CRON_CMD:-crontab -l}"
CRON_JSON=""; CRON_ERR=""
_rs_cron_collect() {
  local raw rc errf out
  CRON_JSON=""; CRON_ERR=""
  errf=$(mktemp "${TMPDIR:-/tmp}/rs-cron.XXXXXX" 2>/dev/null) || { CRON_ERR="crontab_read"; return 0; }
  raw=$($STATUS_CRON_CMD 2>"$errf"); rc=$?
  if [ "$rc" -ne 0 ]; then
    raw=""
    grep -qi "no crontab" "$errf" 2>/dev/null || CRON_ERR="crontab_read"
  fi
  out=$(printf '%s\n' "$raw" | python3 "$RS_HERE/build-runs-json.py" "" "" "$PIPE" cron 2>"$errf") || {
    CRON_ERR="cron_build"; rm -f "$errf"; return 0; }
  if grep -q '^scan_errors=' "$errf" 2>/dev/null; then [ -n "$CRON_ERR" ] || CRON_ERR="log_scan"; fi
  rm -f "$errf"
  CRON_JSON=$(printf '%s' "$out" | jq -ce 'select(type=="array" and length>0)' 2>/dev/null) || CRON_JSON=""
  return 0
}

build_payload() {
  local runs_tsv running queued runs_json completed_json staging_json approved_json goals_json backlog_json ci_queue_json goal_stall_json triggers_json
  runs_tsv=$(derive_runs)
  running=$(printf '%s\n' "$runs_tsv" | awk -F'\t' '$3=="running"{c++} END{print c+0}')
  queued=$(printf '%s\n' "$runs_tsv" | awk -F'\t' '$3=="queued"{c++} END{print c+0}')
  runs_json=$(printf '%s\n' "$runs_tsv" | _rs_build_runs_json)
  [ -n "$runs_json" ] || runs_json='[]'
  completed_json=$(printf '%s\n' "$runs_tsv" | _rs_build_completed_json)
  [ -n "$completed_json" ] || completed_json='[]'
  staging_json=$(_rs_build_list_json staging);   [ -n "$staging_json" ] || staging_json='[]'
  approved_json=$(_rs_build_list_json approved); [ -n "$approved_json" ] || approved_json='[]'
  goals_json=$(_rs_build_goals_json); [ -n "$goals_json" ] || goals_json='[]'
  backlog_json=$(_rs_build_backlog_json); [ -n "$backlog_json" ] || backlog_json='[]'
  goal_stall_json=$(_rs_build_goal_stall_json); [ -n "$goal_stall_json" ] || goal_stall_json='[]'
  triggers_json=$(_rs_build_scheduled_triggers_json); [ -n "$triggers_json" ] || triggers_json='[]'
  ci_queue_json=$(_rs_ci_queue_json)
  local webhook_stale_json; webhook_stale_json=$(webhook_stale_json 2>/dev/null)   # #773: only while enabled and the queue is stale; "" otherwise
  jq -n \
    --argjson webhook_stale "${webhook_stale_json:-null}" \
    --argjson triggers "$triggers_json" \
    --argjson cron "${CRON_JSON:-null}" \
    --argjson goals "$goals_json" \
    --argjson goal_stall "$goal_stall_json" \
    --argjson ci_queue "${ci_queue_json:-null}" \
    --arg sent_at "$SENT_AT" \
    --arg tick "$SUPERVISOR_LAST_TICK" \
    --argjson running "$running" \
    --argjson max "${MAX_CONCURRENT:-3}" \
    --argjson queued "$queued" \
    --argjson runs "$runs_json" \
    --argjson completed "$completed_json" \
    --argjson staging "$staging_json" \
    --argjson approved "$approved_json" \
    --argjson backlog "$backlog_json" \
    '{v: 1, sent_at: $sent_at, supervisor_last_tick: $tick,
      capacity: {running: $running, max: $max, queued: $queued}, runs: $runs, completed: $completed,
      staging: $staging, approved: $approved, backlog: $backlog}
      + (if ($goals | length) > 0 then {goals: $goals} else {} end)
      + (if ($goal_stall | length) > 0 then {goal_stall: $goal_stall} else {} end)
      + (if ($triggers | length) > 0 then {scheduled_triggers: $triggers} else {} end)
      + (if $webhook_stale != null then {webhook_stale: $webhook_stale} else {} end)
      + (if $ci_queue != null then {ci_queue: $ci_queue} else {} end)
      + (if $cron != null then {cron: $cron} else {} end)'
}

SENT_AT=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
SUPERVISOR_LAST_TICK=$(_rs_supervisor_last_tick)
_rs_cron_collect   # top level, not inside PAYLOAD=$(...): CRON_JSON / CRON_ERR must reach this shell
PAYLOAD=$(build_payload)

# --print: payload only, no lock, no network, no state write (ACs 1/2/5's entry point).
if [ "$EVENT" = "--print" ]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

# ---- CI queue collector (issue #643): piggybacks on this heartbeat cycle instead of its own
# cron — fire-and-forget, backgrounded, never blocks or fails this push. The collector throttles
# itself (its own mtime check on $PIPE/status-ci.json), so calling this on every event here is
# harmless. Off by default (CI_QUEUE_COLLECT_ENABLED=0): a dev/test machine on Darwin must not
# start making live GitHub Actions API calls just by running the test suite. Opt in on exactly
# one host (default: the Mac) via ~/.claude/pipeline/config.local.sh.
if [ "${CI_QUEUE_COLLECT_ENABLED:-0}" = "1" ]; then
  # Explicit env on the launch line: PIPE/SLACK_WEBHOOK_URL/SENTRY_DSN/GH_TOKEN/
  # CI_QUEUE_METRICS_ENABLED come from config.sh/config.local.sh as plain (non-exported) shell
  # assignments, sourced into THIS shell by config.sh — they do not cross an exec() into the
  # collector's own process unless passed here. CI_QUEUE_METRICS_ENABLED (issue #660) is defaulted
  # to 1 by config.sh itself once CI_QUEUE_COLLECT_ENABLED=1 is already set (see config.sh) — the
  # live duration/health pull turns on automatically wherever the collector already runs; a host
  # opts OUT by setting CI_QUEUE_METRICS_ENABLED=0 in its own config.local.sh.
  ( PIPE="$PIPE" SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}" SENTRY_DSN="${SENTRY_DSN:-}" \
    GH_TOKEN="${GH_TOKEN:-}" CI_QUEUE_METRICS_ENABLED="${CI_QUEUE_METRICS_ENABLED:-0}" \
    "$RS_HERE/../../infra/ci-runners/ci-queue-collect.sh" >/dev/null 2>&1 & ) 9>&- || true
fi

rs_log() {  # rs_log <line...> — decision + HTTP status only, never the curl command or the token
  mkdir -p "$LOGDIR" 2>/dev/null
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOGDIR/report-status.log" 2>/dev/null
}

rs_post() { curl -sS -X POST --connect-timeout 3 --max-time 5 "$@"; }   # the script's one network call site

# ---- cron collection failure (issue #756 AC12): this host script has no Sentry SDK, so it reuses the
# push-failure path above: one line in report-status.log plus the existing Slack webhook (no new one),
# tags only: release (commit SHA), environment (host), route, and a fixed error class. Never the
# crontab text, a log line or a path. At most once per STATUS_CRON_ALERT_SECS (6 h) while it keeps failing
# (a state file, cleared by the next clean collection) so a broken crontab can't alert every tick. After
# the --print exit on purpose: --print stays network-free. The beat itself is never affected: the
# payload just goes out without a `cron` key.
STATUS_CRON_ALERT_SECS=${STATUS_CRON_ALERT_SECS:-21600}
_rs_cron_alert() {
  local state="$PIPE/status-cron-alert.state" now last _rel _msg
  if [ -z "$CRON_ERR" ]; then rm -f "$state" 2>/dev/null; return 0; fi
  now=$(date +%s); last=$(cat "$state" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$STATUS_CRON_ALERT_SECS" ] || return 0
  printf '%s' "$now" > "$state" 2>/dev/null
  rs_log "$EVENT cron collection failed class=$CRON_ERR"
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    _rel=$(git -C "$RS_HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)
    _msg="status cron collection failed: release=$_rel environment=$(hostname -s 2>/dev/null || echo unknown) route=status-reporter/cron class=$CRON_ERR"
    rs_post -H 'Content-type: application/json' --data "{\"text\": \"$_msg\"}" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
  fi
  return 0
}
_rs_cron_alert

hash_payload() {  # hash the payload minus sent_at/supervisor_last_tick/ci_queue.as_of/cron[].last_run+next_run (else every
                   # tick, or every collector cycle with identical counts, looks like a change)
  python3 -c "
import json, hashlib, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(''); raise SystemExit
d.pop('sent_at', None)
d.pop('supervisor_last_tick', None)
# scheduled_triggers (#769): last_fired_at moves on every dispatch (every 5 min for the release router); a workflow appearing or vanishing still pushes
st = d.get('scheduled_triggers')
if isinstance(st, list):
    for item in st:
        if isinstance(item, dict):
            item.pop('last_fired_at', None)
ci_queue = d.get('ci_queue')
if isinstance(ci_queue, dict):
    ci_queue.pop('as_of', None)
# cron (issue #756): last_run / next_run drift on their own (a */5 job changes them every few minutes),
# which would defeat the write budget; a job appearing, vanishing, or flipping ok/failed still pushes.
cron = d.get('cron')
if isinstance(cron, list):
    for item in cron:
        if isinstance(item, dict):
            item.pop('last_run', None)
            item.pop('next_run', None)
print(hashlib.sha256(json.dumps(d, sort_keys=True).encode()).hexdigest())
" "$1" 2>/dev/null
}

# ---- lock: atomic mkdir with a 60s stale reclaim — portable to macOS bash 3.2 (AC10/AC11) ----
LOCKDIR="$PIPE/status-push.lockdir"
if ! mkdir "$PIPE/status-push.lockdir" 2>/dev/null; then
  age=$(python3 -c "
import os, sys, time
try: print(int(time.time() - os.path.getmtime(sys.argv[1])))
except OSError: print(0)
" "$LOCKDIR" 2>/dev/null)
  if [ -n "$age" ] && [ "$age" -gt 60 ] 2>/dev/null && rmdir "$LOCKDIR" 2>/dev/null && mkdir "$LOCKDIR" 2>/dev/null; then
    :  # stale lock reclaimed
  else
    rs_log "$EVENT skip: lock busy"
    exit 0
  fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# ---- cache read (defensive: a garbled file just yields the defaults — never partially trusted) -
cache_fields=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
for k, dflt in (('last_hash', ''), ('last_push_epoch', 0), ('last_attempt_epoch', 0),
                ('day', ''), ('count', 0), ('fails', 0)):
    print(d.get(k, dflt))
" "$CACHE" 2>/dev/null)
last_hash=""; last_push_epoch=0; last_attempt_epoch=0; day=""; count=0; fails=0
_i=0
while IFS= read -r _line; do
  case $_i in
    0) last_hash=$_line ;;
    1) last_push_epoch=$_line ;;
    2) last_attempt_epoch=$_line ;;
    3) day=$_line ;;
    4) count=$_line ;;
    5) fails=$_line ;;
  esac
  _i=$((_i + 1))
done <<EOF
$cache_fields
EOF
case "$last_push_epoch" in ''|*[!0-9]*) last_push_epoch=0 ;; esac
case "$last_attempt_epoch" in ''|*[!0-9]*) last_attempt_epoch=0 ;; esac
case "$count" in ''|*[!0-9]*) count=0 ;; esac
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac

today=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d'))")
if [ "$day" != "$today" ]; then count=0; day="$today"; fi

hash=$(hash_payload "$PAYLOAD")
now_epoch=$(date +%s)
prev_attempt_epoch=$last_attempt_epoch

should_push=0
if { [ "$hash" != "$last_hash" ] && [ $((now_epoch - last_attempt_epoch)) -ge "$MIN_PUSH_INTERVAL_SECS" ]; } \
   || [ $((now_epoch - last_push_epoch)) -ge "$KEEPALIVE_SECS" ]; then
  should_push=1
fi
[ "$count" -ge "$MAX_PUSHES_PER_DAY" ] && should_push=0

if [ "$should_push" -eq 0 ]; then
  rs_log "$EVENT skip: coalesced/capped/unchanged (count=$count)"
  exit 0
fi

# ---- push --------------------------------------------------------------------------------------
http_code=$(printf '%s' "$PAYLOAD" | rs_post \
  -H "Authorization: Bearer $STATUS_PUSH_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  -o /dev/null -w '%{http_code}' \
  "$STATUS_PUSH_URL" 2>/dev/null)
curl_rc=$?

push_ok=0
case "$curl_rc:$http_code" in
  0:2??) push_ok=1 ;;
esac

if [ "$push_ok" -eq 1 ]; then
  last_hash="$hash"; last_push_epoch=$now_epoch; last_attempt_epoch=$now_epoch
  count=$((count + 1)); fails=0
  rs_log "$EVENT push ok status=$http_code count=$count"
else
  last_attempt_epoch=$now_epoch
  fails=$((fails + 1))
  # log a failure at most once per keep-alive window: fire on the first failure of a streak, or
  # once the previous attempt is more than KEEPALIVE_SECS old.
  if [ "$fails" -eq 1 ] || [ $((now_epoch - prev_attempt_epoch)) -ge "$KEEPALIVE_SECS" ]; then
    rs_log "$EVENT push failed status=${http_code:-000} fails=$fails"
    # #240 observability: alert via the existing Slack webhook (no new one). Tags only: release (commit
    # SHA), environment (host), route. Never the push token or payload body. Same once-per-streak gate.
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
      _rel=$(git -C "$RS_HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)
      _msg="status push failed: release=$_rel environment=$(hostname -s 2>/dev/null || echo unknown) route=status-reporter/push status=${http_code:-000} fails=$fails"
      rs_post -H 'Content-type: application/json' \
        --data "{\"text\": \"$_msg\"}" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
    fi
  fi
fi

tmp=$(mktemp "$PIPE/status-push.state.XXXXXX" 2>/dev/null) && python3 -c "
import json
json.dump({'last_hash': '$last_hash', 'last_push_epoch': $last_push_epoch,
           'last_attempt_epoch': $last_attempt_epoch, 'day': '$day', 'count': $count,
           'fails': $fails, 'last_status': '${http_code:-}'}, open('$tmp', 'w'))
" 2>/dev/null && mv -f "$tmp" "$CACHE" 2>/dev/null

exit 0

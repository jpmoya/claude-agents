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
# Arithmetic (per host unless noted):
#   keep-alive  86400 / KEEPALIVE_SECS(600)        = 144 writes/day  -> 288/day for both hosts,
#                                                                        29% of the 1,000/day cap
#   events      ~10-14 pushes/run x 5-15 runs/day,
#               coalesced at MIN_PUSH_INTERVAL_SECS(10s)             -> ~264 writes/day/host,
#                                                                        ~53% of the cap
#   hard ceiling  2 x MAX_PUSHES_PER_DAY(400)                        = 800/day, 80% of the cap,
#                                                                        whatever the event storm
MIN_PUSH_INTERVAL_SECS=10
KEEPALIVE_SECS=600
MAX_PUSHES_PER_DAY=400
# Host override (2026-09-22): a busy host may raise its own share in ~/.claude/pipeline/config.local.sh
# as long as both hosts together stay under the KV free tier (1,000 writes/day).
[ -f "$HOME/.claude/pipeline/config.local.sh" ] && { _mp=$(grep -E "^MAX_PUSHES_PER_DAY=[0-9]+" "$HOME/.claude/pipeline/config.local.sh" | tail -1 | cut -d= -f2 | tr -dc 0-9); [ -n "$_mp" ] && MAX_PUSHES_PER_DAY=$_mp; }

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

build_payload() {
  local runs_tsv running queued runs_json completed_json staging_json approved_json
  runs_tsv=$(derive_runs)
  running=$(printf '%s\n' "$runs_tsv" | awk -F'\t' '$3=="running"{c++} END{print c+0}')
  queued=$(printf '%s\n' "$runs_tsv" | awk -F'\t' '$3=="queued"{c++} END{print c+0}')
  runs_json=$(printf '%s\n' "$runs_tsv" | _rs_build_runs_json)
  [ -n "$runs_json" ] || runs_json='[]'
  completed_json=$(printf '%s\n' "$runs_tsv" | _rs_build_completed_json)
  [ -n "$completed_json" ] || completed_json='[]'
  staging_json=$(_rs_build_list_json staging);   [ -n "$staging_json" ] || staging_json='[]'
  approved_json=$(_rs_build_list_json approved); [ -n "$approved_json" ] || approved_json='[]'
  jq -n \
    --arg sent_at "$SENT_AT" \
    --arg tick "$SUPERVISOR_LAST_TICK" \
    --argjson running "$running" \
    --argjson max "${MAX_CONCURRENT:-3}" \
    --argjson queued "$queued" \
    --argjson runs "$runs_json" \
    --argjson completed "$completed_json" \
    --argjson staging "$staging_json" \
    --argjson approved "$approved_json" \
    '{v: 1, sent_at: $sent_at, supervisor_last_tick: $tick,
      capacity: {running: $running, max: $max, queued: $queued}, runs: $runs, completed: $completed,
      staging: $staging, approved: $approved}'
}

SENT_AT=$(python3 -c "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
SUPERVISOR_LAST_TICK=$(_rs_supervisor_last_tick)
PAYLOAD=$(build_payload)

# --print: payload only, no lock, no network, no state write (ACs 1/2/5's entry point).
if [ "$EVENT" = "--print" ]; then
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

rs_log() {  # rs_log <line...> — decision + HTTP status only, never the curl command or the token
  mkdir -p "$LOGDIR" 2>/dev/null
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOGDIR/report-status.log" 2>/dev/null
}

hash_payload() {  # hash the payload minus sent_at/supervisor_last_tick (else every tick looks new)
  python3 -c "
import json, hashlib, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(''); raise SystemExit
d.pop('sent_at', None)
d.pop('supervisor_last_tick', None)
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
http_code=$(printf '%s' "$PAYLOAD" | curl -sS -X POST --connect-timeout 3 --max-time 5 \
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
  fi
fi

tmp=$(mktemp "$PIPE/status-push.state.XXXXXX" 2>/dev/null) && python3 -c "
import json
json.dump({'last_hash': '$last_hash', 'last_push_epoch': $last_push_epoch,
           'last_attempt_epoch': $last_attempt_epoch, 'day': '$day', 'count': $count,
           'fails': $fails, 'last_status': '${http_code:-}'}, open('$tmp', 'w'))
" 2>/dev/null && mv -f "$tmp" "$CACHE" 2>/dev/null

exit 0

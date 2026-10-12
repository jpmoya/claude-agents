#!/bin/bash
# Shared launcher helpers (issue #8), sourced by orchestrate.sh and supervisor.sh right after config.sh.
# Reads $PIPE, $MAX_CONCURRENT and $MEM_FLOOR_MB at call time, so it does not source config.sh itself.
# marker_last_jq needs marker_re from hooks/pipeline-markers.sh, which both launchers also source.
pipeline_host() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

# run_key <owner/repo> <issue> — the one name every per-run file and queue entry is keyed by (#213):
# orch-<owner>_<repo>-<issue>. Two repos can hold the same issue number on one host. Callers that glob
# orch-*.pid take the issue as the text after the last '-' and never parse owner/repo back out of the key.
run_key() { printf 'orch-%s-%s' "${1//\//_}" "$2"; }

SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there

# queue_files_by_age — prints every $QUEUE/*.json path, oldest queued_at first (file mtime when missing/unparseable,
# then name). Replaces the number-based filename sort: names now start with the owner/repo, not the issue.
queue_files_by_age() {
  python3 - "$QUEUE" <<'PY' 2>/dev/null
import glob, json, os, sys, datetime
rows = []
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        t = datetime.datetime.strptime(json.load(open(f))["queued_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        try: t = os.path.getmtime(f)
        except OSError: continue
    rows.append((t, f))
for t, f in sorted(rows):
    print(f)
PY
}

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid "$PIPE"/intake-*.pid; do   # intake runs (#114) count against MAX_CONCURRENT too
    [ -e "$f" ] || continue
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

marker_last_jq() {  # prints (no gh call) the jq expression yielding the newest real routing marker first line, or "none"; NOTEs and off-vocabulary lines are inert
  printf '[.comments[] | .body | split("\\n")[0] | select(test(%s))] | last // "none"' "$(marker_re | jq -Rs .)"
}

marker_name_from_line() {  # <first line of a routing-marker comment | none> -> bare marker name ("TESTS APPROVED"), empty for none
  case "$1" in
    none|"") return 0 ;;
    *) printf '%s' "$1" | sed -e 's/^\*\*\[[^]]*\] //' -e 's/\*\*.*$//' -e 's/:.*$//' -e 's/[[:space:]]*$//' ;;
  esac
}

# write_title_marker <repo dir> <issue> <rm-title-on-fail 0|1> <run key> — ONE gh call (--json title,comments) refreshes
# <run key>.title and <run key>.marker. A failed fetch removes the marker (never stale); the title only when asked.
write_title_marker() {
  local repo=$1 issue=$2 rmtitle=${3:-0} key=${4:?run key required} info title line marker
  info=$(cd "$repo" && gh issue view "$issue" --json title,comments 2>/dev/null </dev/null) || info=""
  title=$(printf '%s' "$info" | jq -r '.title // empty' 2>/dev/null) || title=""
  if [ -n "$title" ]; then printf '%s\n' "$title" > "$PIPE/$key.title"
  elif [ "$rmtitle" = 1 ]; then rm -f "$PIPE/$key.title"; fi
  marker=""
  if [ -n "$info" ]; then
    line=$(printf '%s' "$info" | jq -r "$(marker_last_jq)" 2>/dev/null) || line=""
    marker=$(marker_name_from_line "$line")
  fi
  if [ -n "$marker" ]; then printf '%s\n' "$marker" > "$PIPE/$key.marker"; else rm -f "$PIPE/$key.marker"; fi
}

# limit_kind_of <file> — looks at the last 20 lines, case-insensitive: a `hit your … limit` line prints monthly_spend
# (contains "spend limit"), weekly (contains "weekly limit") or other; no match prints nothing.
limit_kind_of() {
  local line
  line=$(tail -n 20 "$1" 2>/dev/null | grep -iE 'hit your.*limit' | tail -1) || true
  [ -n "$line" ] || return 0
  case $(printf '%s' "$line" | tr '[:upper:]' '[:lower:]') in
    *"spend limit"*) echo monthly_spend ;;
    *"weekly limit"*) echo weekly ;;
    *) echo other ;;
  esac
}

# pipeline_event <event> [jq --arg/--argjson pairs…] — appends one row (v, ts, host, event + the given fields) to
# $LOGDIR/events.jsonl. Any failure is swallowed: logging never blocks a launch or a supervisor tick.
pipeline_event() {
  local ev=${1:-}; shift 2>/dev/null || true
  local dir=${LOGDIR:-$HOME/logs/pipeline} row
  row=$(jq -nc --arg event "$ev" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "$(pipeline_host)" "$@" \
    '{v:1,ts:$ts,host:$host,event:$event} + ($ARGS.named | del(.event,.ts,.host))' 2>/dev/null) || return 0
  { mkdir -p "$dir" && printf '%s\n' "$row" >> "$dir/events.jsonl"; } 2>/dev/null || true
  return 0
}

# Slack posts for pipeline events (moved here from supervisor.sh so orchestrate.sh and install.sh share one path, #213).
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
  if [ -z "$issue" ]; then msg="$emoji $reason"   # no ticket (install-time migration): plain text
  elif [ -z "$owner_repo" ]; then msg="$emoji #$issue — $reason"; fi   # repo unresolved (launch failure): no link
  thread=""; [ -z "$issue" ] || thread=$(slack_thread_for "$owner_repo" "$issue" 2>/dev/null) || thread=""
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
    command -v slog >/dev/null 2>&1 && slog "[slack] #$issue — posted to engineering"
  else
    command -v slog >/dev/null 2>&1 && slog "[slack] #$issue — post failed: $(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error','unknown'))" 2>/dev/null || echo 'curl error')"
  fi
  return 0
}

# pipeline_error <route> <issue|""> <owner/repo|""> <message> — one `error` row through pipeline_event (release = the
# claude-agents checkout commit SHA, host from pipeline_event) and one notify_engineering post. Carries no tokens or
# webhook URLs: only the route, the ticket, owner/repo and the message. Never fails the caller.
PL_CHECKOUT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)
pipeline_error() {
  local route=$1 issue=${2:-} owner_repo=${3:-} msg=${4:-} sha
  sha=$(git -C "$PL_CHECKOUT" rev-parse HEAD 2>/dev/null) || sha=unknown
  pipeline_event error --arg route "$route" --arg release "$sha" --arg repo "$owner_repo" --arg issue "$issue" --arg message "$msg"
  notify_engineering "$issue" ":rotating_light:" "$msg" "$owner_repo" || true
  return 0
}

# log_run_launch <owner/repo> <issue> <reason> <restart_n> <queue_wait_s|""> — writes $PIPE/<run key>.run-id, clears
# .exit-logged and appends the run_launch row. Call right after the process is started.
log_run_launch() {
  local repo=$1 issue=$2 reason=$3 restart_n=${4:-0} qw=${5:-} run_id key
  key=$(run_key "$repo" "$issue")
  run_id="$(pipeline_host)-$key-$(date +%s)"
  rm -f "$PIPE/$key.exit-logged" 2>/dev/null
  printf '%s\n' "$run_id" > "$PIPE/$key.run-id" 2>/dev/null || true
  case "$qw" in ''|*[!0-9]*) qw=null ;; esac
  case "$issue" in ''|*[!0-9]*) return 0 ;; esac
  pipeline_event run_launch --arg run_id "$run_id" --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
    --argjson restart_n "${restart_n:-0}" --argjson queue_wait_s "$qw"
  return 0
}

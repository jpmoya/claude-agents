#!/bin/bash
# Shared launcher helpers (issue #8), sourced by orchestrate.sh and supervisor.sh right after config.sh.
# Reads $PIPE, $MAX_CONCURRENT and $MEM_FLOOR_MB at call time, so it does not source config.sh itself.
# marker_last_jq needs marker_re from hooks/pipeline-markers.sh, which both launchers also source.
pipeline_host() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there

count_running() {
  local n=0
  for f in "$PIPE"/orch-*.pid "$PIPE"/intake-*.pid; do   # intake runs (#114) count against MAX_CONCURRENT too
    [ -e "$f" ] || continue
    pid_alive "$f" && n=$((n + 1))
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

# write_title_marker <repo dir> <issue> <rm-title-on-fail 0|1> — ONE gh call (--json title,comments) refreshes
# orch-<issue>.title and orch-<issue>.marker. A failed fetch removes the marker (never stale); the title only when asked.
write_title_marker() {
  local repo=$1 issue=$2 rmtitle=${3:-0} info title line marker
  info=$(cd "$repo" && gh issue view "$issue" --json title,comments 2>/dev/null </dev/null) || info=""
  title=$(printf '%s' "$info" | jq -r '.title // empty' 2>/dev/null) || title=""
  if [ -n "$title" ]; then printf '%s\n' "$title" > "$PIPE/orch-$issue.title"
  elif [ "$rmtitle" = 1 ]; then rm -f "$PIPE/orch-$issue.title"; fi
  marker=""
  if [ -n "$info" ]; then
    line=$(printf '%s' "$info" | jq -r "$(marker_last_jq)" 2>/dev/null) || line=""
    marker=$(marker_name_from_line "$line")
  fi
  if [ -n "$marker" ]; then printf '%s\n' "$marker" > "$PIPE/orch-$issue.marker"; else rm -f "$PIPE/orch-$issue.marker"; fi
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

# log_run_launch <owner/repo> <issue> <reason> <restart_n> <queue_wait_s|""> — writes $PIPE/orch-<issue>.run-id, clears
# .exit-logged and appends the run_launch row. Call right after the process is started.
log_run_launch() {
  local repo=$1 issue=$2 reason=$3 restart_n=${4:-0} qw=${5:-} run_id
  run_id="$(pipeline_host)-orch-$issue-$(date +%s)"
  rm -f "$PIPE/orch-$issue.exit-logged" 2>/dev/null
  printf '%s\n' "$run_id" > "$PIPE/orch-$issue.run-id" 2>/dev/null || true
  case "$qw" in ''|*[!0-9]*) qw=null ;; esac
  case "$issue" in ''|*[!0-9]*) return 0 ;; esac
  pipeline_event run_launch --arg run_id "$run_id" --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" \
    --argjson restart_n "${restart_n:-0}" --argjson queue_wait_s "$qw"
  return 0
}

# claim_winner <local_path> <issue> — prints the host of the earliest "**[supervisor] NOTE** claim: <host> <ts>" comment
# inside CLAIM_WINDOW_SECS (empty if none). Shared by dispatch and hand launch (#217). A failed comment read returns 1,
# prints nothing and records a claim_lookup_failed event (issue number only), so callers fail closed.
# claim_alert <issue> <stage> — best-effort Slack alert (existing SLACK_WEBHOOK_URL) for a claim-lookup failure. Host and
# issue number only; silent when no webhook is configured. Never fails the caller.
claim_alert() {
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"claim lookup failed (#${1:-0}, stage $2, host $(hostname -s)); launch refused\"}" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
}

# launch_alert <goal id> <issue> — best-effort Slack alert (existing SLACK_WEBHOOK_URL) when deliver.sh register could not
# launch. Goal id and issue number only (no instruction text). Never fails the caller.
launch_alert() {
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"deliver.sh register: launch failed for goal ${1:-?} (issue #${2:-0}, host $(hostname -s)); closed as stopped\"}" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
}

claim_winner() {
  local path=$1 issue=$2 cutoff out
  cutoff=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "${CLAIM_WINDOW_SECS:-600}") \
    || { pipeline_event claim_lookup_failed --argjson issue "${issue:-0}" --arg stage cutoff; claim_alert "$issue" cutoff; return 1; }
  out=$(cd "$path" && gh issue view "$issue" --json comments \
    --jq "[.comments[] | select(.body | startswith(\"**[supervisor] NOTE** claim: \")) | select(.createdAt > \"$cutoff\")] | sort_by(.createdAt) | first | .body // \"\"" 2>/dev/null) \
    || { pipeline_event claim_lookup_failed --argjson issue "${issue:-0}" --arg stage gh; claim_alert "$issue" gh; return 1; }
  printf '%s\n' "$out" | awk '{print $4}'
}

# pipeline_error_alert <route> <message> — #332: one Slack alert on the existing webhook; tags release (commit SHA), environment (host), route.
pipeline_error_alert() {
  local rel env; rel=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --short HEAD 2>/dev/null || echo nogit); env=$(pipeline_host)
  mkdir -p "${LOGDIR:-$HOME/logs/pipeline}" 2>/dev/null
  printf '[%s] pipeline error route=%s: %s\n' "$(date -u +%FT%TZ)" "$1" "$2" >> "${LOGDIR:-$HOME/logs/pipeline}/errors.log" 2>/dev/null || true
  [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0
  curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"pipeline error release=$rel environment=${env:-unknown} route=$1: $2\"}" \
    "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 </dev/null || true
}

# boot_epoch — host boot time in epoch seconds; PIPELINE_BOOT_EPOCH overrides (tests). Fails if unreadable.
boot_epoch() {
  local b=${PIPELINE_BOOT_EPOCH:-}
  if [ -z "$b" ]; then
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then b=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\).*/\1/p')
    else b=$(awk '/^btime/ {print $2}' "${PIPELINE_PROC_STAT:-/proc/stat}" 2>/dev/null); fi
  fi
  case "$b" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$b"
}

# iso_to_epoch <YYYY-MM-DDTHH:MM:SSZ> — UTC epoch by pure arithmetic (no BSD/GNU date split); prints nothing on a bad shape
iso_to_epoch() {
  case "$1" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) return 1 ;; esac
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) era yoe doy doe
  [ "$m" -le 2 ] && y=$((y - 1))
  era=$((y / 400)); yoe=$((y - era * 400))
  doy=$(( (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1 )); doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $(( (era * 146097 + doe - 719468) * 86400 + 10#${1:11:2} * 3600 + 10#${1:14:2} * 60 + 10#${1:17:2} ))
}

# pid_alive <pidfile> — kill -0 on the stored pid AND the sibling .launched-at later than host boot (a pid stored before a
# reboot may belong to an unrelated new process). No .launched-at: kill -0 alone. Unreadable boot time: alert, kill -0 alone.
pid_alive() {
  local pf=$1 pid la boot le
  pid=$(cat "$pf" 2>/dev/null); [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  la=$(cat "${pf%.pid}.launched-at" 2>/dev/null); [ -n "$la" ] || return 0
  boot=$(boot_epoch) || { pipeline_error_alert pid_alive "boot time unreadable; falling back to kill -0"; return 0; }
  le=$(iso_to_epoch "$la"); case "$le" in ''|*[!0-9]*) return 0 ;; esac
  [ "$le" -gt "$boot" ]
}

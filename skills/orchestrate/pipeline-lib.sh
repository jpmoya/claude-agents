#!/bin/bash
# Shared launcher helpers (issue #8), sourced by orchestrate.sh and supervisor.sh right after config.sh.
# Reads $PIPE, $MAX_CONCURRENT and $MEM_FLOOR_MB at call time, so it does not source config.sh itself.
# marker_last_jq needs marker_re from hooks/pipeline-markers.sh, which both launchers also source.
pipeline_host() { hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'; }

SETSID=$(command -v setsid >/dev/null 2>&1 && echo setsid || true)   # absent on macOS; nohup + & is enough there

# run_key <owner/repo> <issue> — prints <owner>_<repo>-<N> (#318): the one key of every per-run, queue and stage file
# (orch-<key>.*, <key>-<agent>-before.txt, locked-<key>.txt, run-<key>-<agent>.log). Same-numbered tickets of two repos
# never share a file. The issue is kept as written (leading zeros included): no arithmetic, so no octal reading.
run_key() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  printf '%s-%s\n' "${1//\//_}" "$2"
}

# repo_slug <local checkout> — prints owner/repo from the checkout's origin (local, no network); falls back to gh.
repo_slug() {
  local u slug
  u=$(git -C "$1" config --get remote.origin.url 2>/dev/null) || u=""
  slug=$(printf '%s' "$u" | sed -E -e 's#^.*github\.com[:/]+##' -e 's#\.git$##' -e 's#/+$##')
  case "$slug" in */*) ;; *) slug="" ;; esac
  [ -n "$slug" ] || slug=$(cd "$1" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null </dev/null) || slug=""
  printf '%s' "$slug"
}

# rk_of <local checkout> <issue> — run key of a checkout's ticket; "unknown" repo when it cannot be resolved.
rk_of() {
  local slug; slug=$(repo_slug "$1"); run_key "${slug:-unknown/unknown}" "$2"
}

# rk_pick <local checkout> <issue> — the file stem to read a run under: its run key, or (read-both fallback, #318) the
# legacy bare <N> when only a legacy set exists and its .repo names the same repo. Never returns another repo's legacy set.
rk_pick() {
  local k rf
  k=$(rk_of "$1" "$2")
  if [ ! -e "$PIPE/orch-$k.repo" ] && [ ! -e "$PIPE/orch-$k.pid" ]; then
    rf=$(cat "$PIPE/orch-$2.repo" 2>/dev/null) || rf=""
    if [ -n "$rf" ] && [ "$(repo_slug "$rf")" = "$(repo_slug "$1")" ]; then k=$2; fi
  fi
  printf '%s' "$k"
}

# migrate_legacy_runs — one-time, per run atomic rename of legacy orch-<N>.* sets to the run key (#318). A set is
# migrated only when orch-<N>.repo names a checkout whose origin resolves; a missing/unresolvable repo file leaves the
# whole set untouched. All files of the run move (orch-<N>.*, queue/orch-<N>.json, run-<N>-*.log, <N>-*-before|nags.txt)
# or none do: a destination that already exists, or a failed mv, leaves/restores the legacy names, records one error row
# (pipeline_event error: release = checkout SHA, host, route) and, once per run, goes to notify_engineering.
# TODO(next ticket): remove together with the read-both fallback.
migrate_legacy_runs() {
  local f n seen=" " repo slug key src dst pairs ok done_pairs i conflict rel
  for f in "$PIPE"/orch-[0-9]*.*; do
    [ -e "$f" ] || continue
    n=${f##*/orch-}; n=${n%%.*}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    case "$seen" in *" $n "*) continue ;; esac
    seen="$seen$n "
    repo=$(cat "$PIPE/orch-$n.repo" 2>/dev/null) || repo=""
    [ -n "$repo" ] || continue
    slug=$(repo_slug "$repo"); [ -n "$slug" ] || continue
    key=$(run_key "$slug" "$n")
    pairs=()
    for src in "$PIPE"/orch-"$n".* "$QUEUE/orch-$n.json" "$PIPE"/run-"$n"-*.log "$PIPE"/"$n"-*-before.txt "$PIPE"/"$n"-*-nags.txt; do
      [ -e "$src" ] || continue
      case "${src##*/}" in
        orch-"$n".*) dst="${src%/*}/orch-$key.${src##*/orch-$n.}" ;;
        run-"$n"-*) dst="${src%/*}/run-$key-${src##*/run-$n-}" ;;
        *) dst="${src%/*}/$key-${src##*/$n-}" ;;
      esac
      pairs+=("$src|$dst")
    done
    conflict=""
    for i in "${pairs[@]}"; do [ ! -e "${i#*|}" ] || conflict="${i#*|}"; done
    ok=1; done_pairs=()
    if [ -z "$conflict" ]; then
      for i in "${pairs[@]}"; do
        if mv "${i%%|*}" "${i#*|}" 2>/dev/null; then done_pairs+=("$i"); else ok=0; break; fi
      done
      if [ "$ok" = 0 ]; then for i in ${done_pairs[@]+"${done_pairs[@]}"}; do mv "${i#*|}" "${i%%|*}" 2>/dev/null; done; fi
    else ok=0; fi
    if [ "$ok" = 1 ]; then
      command -v slog >/dev/null 2>&1 && slog "[migrate] orch-$n.* -> orch-$key.* (${#pairs[@]} files)"
      continue
    fi
    # one error row and one alert per run key until it is resolved
    [ -e "$PIPE/migrate-error-$key" ] && continue
    : > "$PIPE/migrate-error-$key" 2>/dev/null || true
    rel=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || echo unknown)
    pipeline_event error --arg level error --arg route supervisor/migrate-run-key --arg release "$rel" \
      --arg msg "legacy run set orch-$n.* could not be renamed to orch-$key.*; left untouched" --argjson issue "$n"
    command -v slog >/dev/null 2>&1 && slog "[migrate] error: legacy orch-$n.* not renamed to $key (release=$rel)"
    command -v notify_engineering >/dev/null 2>&1 \
      && notify_engineering "$n" ":warning:" "Run-key migration failed; legacy files left untouched (release $rel)" "$slug" || true
  done
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

# write_title_marker <repo dir> <issue> <rm-title-on-fail 0|1> [<run_key>] — ONE gh call (--json title,comments) refreshes
# orch-<key>.title and orch-<key>.marker (key = run_key of the checkout's repo + issue). A failed fetch removes the marker (never stale); the title only when asked.
write_title_marker() {
  local repo=$1 issue=$2 rmtitle=${3:-0} rk=${4:-} info title line marker
  [ -n "$rk" ] || rk=$(rk_of "$repo" "$issue")
  info=$(cd "$repo" && gh issue view "$issue" --json title,comments 2>/dev/null </dev/null) || info=""
  title=$(printf '%s' "$info" | jq -r '.title // empty' 2>/dev/null) || title=""
  if [ -n "$title" ]; then printf '%s\n' "$title" > "$PIPE/orch-$rk.title"
  elif [ "$rmtitle" = 1 ]; then rm -f "$PIPE/orch-$rk.title"; fi
  marker=""
  if [ -n "$info" ]; then
    line=$(printf '%s' "$info" | jq -r "$(marker_last_jq)" 2>/dev/null) || line=""
    marker=$(marker_name_from_line "$line")
  fi
  if [ -n "$marker" ]; then printf '%s\n' "$marker" > "$PIPE/orch-$rk.marker"; else rm -f "$PIPE/orch-$rk.marker"; fi
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

# log_run_launch <owner/repo> <issue> <reason> <restart_n> <queue_wait_s|""> [<run_key>] — writes $PIPE/orch-<run_key>.run-id, clears
# .exit-logged and appends the run_launch row. Call right after the process is started.
log_run_launch() {
  local repo=$1 issue=$2 reason=$3 restart_n=${4:-0} qw=${5:-} rk=${6:-} run_id
  [ -n "$rk" ] || rk=$(run_key "${repo:-unknown/unknown}" "$issue")
  run_id="$(pipeline_host)-orch-$issue-$(date +%s)"
  rm -f "$PIPE/orch-$rk.exit-logged" 2>/dev/null
  printf '%s\n' "$run_id" > "$PIPE/orch-$rk.run-id" 2>/dev/null || true
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
